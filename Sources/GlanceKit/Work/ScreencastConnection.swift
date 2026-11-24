import Foundation
import GlanceCore

/// What a screencast connection tells the recorder about the browser's pages. Delivered on the main queue.
enum ScreencastEvent: Equatable {
  case created(target: String, url: String)
  case changed(target: String, url: String)
  case destroyed(target: String)
  /// The browser went away or the socket failed. Not sent after `close()`.
  case closed
}

/// The recorder's view of the browser (Command Center, spec 2026-11-01-command-center-design.md §4.2): which pages exist,
/// and a stream of JPEG frames from the pages it asked for. A protocol so the recorder's tests run without a browser.
protocol ScreencastConnecting: AnyObject {
  /// Target discovery and the close. Called on the main queue.
  var onEvent: ((ScreencastEvent) -> Void)? { get set }
  /// A frame, already acknowledged: target, JPEG bytes, and the browser's time for it (seconds since 1970). Called on the
  /// connection's own queue, never on main, so the recorder must hand the bytes on without waiting.
  var onFrame: (@Sendable (String, Data, Double) -> Void)? { get set }

  /// Connects and starts reporting pages (`Target.setDiscoverTargets`), so URLs and navigations arrive as events.
  func open() async throws
  /// Attaches to a page (once: a second call for an attached page does nothing). The attachment outlives a screencast, so
  /// a page that finishes a clip and starts the next one keeps it.
  func attach(target: String) async throws
  func startScreencast(target: String) async throws
  func stopScreencast(target: String) async throws
  func close()
}

/// A Chrome DevTools Protocol connection of its own to the Glance browser, for screencasts. It listens on the browser's real
/// debugging port, never on the relay ports, so recording isn't counted as a client of the relay.
///
/// Everything here runs on one private serial queue: reading the socket, parsing, acknowledging frames. A frame is a
/// message of 100 KB or more, and the main thread never sees it.
final class ScreencastConnection: ScreencastConnecting, @unchecked Sendable {
  struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  var onEvent: ((ScreencastEvent) -> Void)?
  var onFrame: (@Sendable (String, Data, Double) -> Void)?

  /// Where messages go; the socket once open. Replaced in tests.
  var outgoing: (String) -> Void = { _ in }
  /// How an event reaches the recorder: the main queue. Replaced in tests.
  var deliverEvent: (ScreencastEvent) -> Void = { _ in }

  private let port: Int
  private let queue = DispatchQueue(label: "dev.glance.screencast", qos: .userInitiated)
  private var task: URLSessionWebSocketTask?
  private var nextId = 1
  private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
  private var sessionOfTarget: [String: String] = [:]
  private var targetOfSession: [String: String] = [:]
  private var closed = false

  init(port: Int) {
    self.port = port
    deliverEvent = { [weak self] event in
      DispatchQueue.main.async { self?.onEvent?(event) }
    }
  }

  // MARK: Connecting

  func open() async throws {
    let info = URL(string: "http://127.0.0.1:\(port)/json/version")!
    let (data, _) = try await URLSession.shared.data(from: info)
    guard let text = JSONValue.parse(String(decoding: data, as: UTF8.self))?["webSocketDebuggerUrl"]?.string,
          let url = URL(string: text) else { throw Failure(message: "No browser on port \(port)") }
    let task = URLSession.shared.webSocketTask(with: url)
    task.maximumMessageSize = 64 * 1024 * 1024 // a frame is far bigger than the default 1 MiB
    queue.sync {
      self.task = task
      self.outgoing = { [weak self] text in
        task.send(.string(text)) { error in
          if error != nil { self?.queue.async { self?.shutdown() } }
        }
      }
    }
    task.resume()
    receive(task)
    // Without this the browser reports no navigations on this connection (measured), and the recorder has no URLs.
    _ = try await command("Target.setDiscoverTargets", ["discover": true])
  }

  func close() {
    queue.async {
      guard !self.closed else { return }
      self.closed = true
      self.task?.cancel(with: .normalClosure, reason: nil)
      self.failPending()
    }
  }

  private func receive(_ task: URLSessionWebSocketTask) {
    task.receive { [weak self] result in
      guard let self else { return }
      self.queue.async {
        switch result {
        case .failure:
          self.shutdown()
        case .success(let message):
          switch message {
          case .string(let text): self.handle(text: text)
          case .data(let data): self.handle(text: String(decoding: data, as: UTF8.self))
          @unknown default: break
          }
          if !self.closed { self.receive(task) }
        }
      }
    }
  }

  /// The socket failed or the browser quit. Queue only.
  private func shutdown() {
    guard !closed else { return }
    closed = true
    task?.cancel(with: .goingAway, reason: nil)
    failPending()
    deliverEvent(.closed)
  }

  private func failPending() {
    let waiting = pending
    pending = [:]
    for continuation in waiting.values { continuation.resume(throwing: Failure(message: "The browser connection closed")) }
  }

  // MARK: Commands

  private func command(_ method: String, _ params: JSONValue = [:], session: String? = nil) async throws -> JSONValue {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        guard !self.closed else { return continuation.resume(throwing: Failure(message: "The browser connection closed")) }
        let id = self.nextId
        self.nextId += 1
        self.pending[id] = continuation
        self.outgoing(self.text(id: id, method, params, session))
      }
    }
  }

  private func text(id: Int, _ method: String, _ params: JSONValue, _ session: String?) -> String {
    String(decoding: CDPMessage.command(id: id, method: method, params: params, sessionId: session), as: UTF8.self)
  }

  private func onQueue<T>(_ body: @escaping () -> T) async -> T {
    await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: body()) } }
  }

  func attach(target: String) async throws {
    if await onQueue({ self.sessionOfTarget[target] != nil }) { return }
    let reply = try await command("Target.attachToTarget", ["targetId": .string(target), "flatten": true])
    guard let session = reply["sessionId"]?.string else { throw Failure(message: "The browser wouldn't attach to the page") }
    await onQueue { self.adopt(target: target, session: session) }
  }

  func startScreencast(target: String) async throws {
    guard let session = await onQueue({ self.sessionOfTarget[target] }) else { throw Failure(message: "The page isn't attached") }
    // Every frame: a static page paints once, and the recorder throttles what it writes.
    try await sessionCommand("Page.startScreencast", ["format": "jpeg", "quality": 70, "maxWidth": 1280, "maxHeight": 720,
                                                      "everyNthFrame": 1], target: target, session: session)
  }

  func stopScreencast(target: String) async throws {
    guard let session = await onQueue({ self.sessionOfTarget[target] }) else { return }
    try await sessionCommand("Page.stopScreencast", [:], target: target, session: session)
  }

  /// A command for an attached page. When the browser says the attachment is gone ("Session with given id not found",
  /// after the page crashed or was detached), it is forgotten, so the next clip attaches again.
  private func sessionCommand(_ method: String, _ params: JSONValue, target: String, session: String) async throws {
    do {
      _ = try await command(method, params, session: session)
    } catch {
      if error.localizedDescription.localizedCaseInsensitiveContains("not found") {
        await onQueue { if self.sessionOfTarget[target] == session { self.forget(target: target) } }
      }
      throw error
    }
  }

  /// Remembers that `session` is the attachment to `target`. Queue only.
  func adopt(target: String, session: String) {
    sessionOfTarget[target] = session
    targetOfSession[session] = target
  }

  private func forget(target: String) {
    if let session = sessionOfTarget.removeValue(forKey: target) { targetOfSession[session] = nil }
  }

  // MARK: Incoming

  /// Hands a message to the connection's queue, as the socket does. For tests.
  func deliver(text: String) { queue.async { self.handle(text: text) } }

  /// One message from the browser. Queue only (tests call it directly).
  func handle(text: String) {
    guard let message = CDPMessage.parse(text) else { return }
    switch message {
    case .response(let id, let result, let error):
      guard let continuation = pending.removeValue(forKey: id) else { return }
      if let error {
        continuation.resume(throwing: Failure(message: error))
      } else {
        continuation.resume(returning: result ?? [:])
      }
    case .event(let method, let params, let session):
      switch method {
      case "Page.screencastFrame":
        frame(params, cdpSession: session)
      case "Target.targetCreated":
        guard let info = params["targetInfo"], info["type"]?.string == "page", let id = info["targetId"]?.string else { return }
        deliverEvent(.created(target: id, url: info["url"]?.string ?? ""))
      case "Target.targetInfoChanged":
        guard let info = params["targetInfo"], info["type"]?.string == "page", let id = info["targetId"]?.string else { return }
        deliverEvent(.changed(target: id, url: info["url"]?.string ?? ""))
      case "Target.targetDestroyed":
        guard let id = params["targetId"]?.string else { return }
        forget(target: id)
        deliverEvent(.destroyed(target: id))
      case "Target.detachedFromTarget":
        if let session = params["sessionId"]?.string, let target = targetOfSession[session] { forget(target: target) }
      default:
        break
      }
    }
  }

  /// Acks first (the browser sends nothing more until it is acked, wanted or not), then hands the picture on.
  private func frame(_ params: JSONValue, cdpSession: String?) {
    guard let cdpSession else { return }
    if let number = params["sessionId"]?.int {
      // `params.sessionId` is the frame's number; the CDP session id goes in the message itself. They differ.
      let id = nextId
      nextId += 1
      outgoing(text(id: id, "Page.screencastFrameAck", ["sessionId": .number(Double(number))], cdpSession))
    }
    guard let target = targetOfSession[cdpSession], let encoded = params["data"]?.string,
          let data = Data(base64Encoded: encoded) else { return }
    var time = Date().timeIntervalSince1970
    if case .number(let stamp)? = params["metadata"]?["timestamp"] { time = stamp }
    onFrame?(target, data, time)
  }
}
