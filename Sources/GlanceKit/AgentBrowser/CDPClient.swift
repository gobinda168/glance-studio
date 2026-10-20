import Foundation
import GlanceCore

/// One Chrome DevTools Protocol connection to a browser (flat sessions: a page's commands carry its `sessionId`). For
/// Glance browser panel: target discovery, screencast frames, input, viewport and screenshots.
@MainActor
public final class CDPClient {
  public enum Failure: LocalizedError {
    case closed
    case protocolError(String)
    public var errorDescription: String? {
      switch self {
      case .closed: "The browser connection closed"
      case .protocolError(let message): message
      }
    }
  }

  /// Every event: method, params, sessionId.
  public var onEvent: ((String, JSONValue, String?) -> Void)?
  public var onClose: (() -> Void)?

  private let task: URLSessionWebSocketTask
  private var nextId = 1
  private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
  private var closed = false

  /// `url`: the browser's `webSocketDebuggerUrl` (from `/json/version`).
  public init(url: URL) {
    task = URLSession.shared.webSocketTask(with: url)
    task.maximumMessageSize = 64 * 1024 * 1024 // screencast frames and screenshots
    task.resume()
    receive()
  }

  /// The browser behind a CDP port: `http://127.0.0.1:<port>/json/version`.
  public static func connect(port: Int) async throws -> CDPClient {
    let info = URL(string: "http://127.0.0.1:\(port)/json/version")!
    let (data, _) = try await URLSession.shared.data(from: info)
    guard let text = JSONValue.parse(String(decoding: data, as: UTF8.self))?["webSocketDebuggerUrl"]?.string,
          let url = URL(string: text) else { throw Failure.protocolError("No browser on port \(port)") }
    return CDPClient(url: url)
  }

  @discardableResult
  public func send(_ method: String, _ params: JSONValue = [:], session: String? = nil) async throws -> JSONValue {
    guard !closed else { throw Failure.closed }
    let id = nextId
    nextId += 1
    let message = String(decoding: CDPMessage.command(id: id, method: method, params: params, sessionId: session), as: UTF8.self)
    return try await withCheckedThrowingContinuation { continuation in
      pending[id] = continuation
      task.send(.string(message)) { error in
        guard let error else { return }
        DispatchQueue.main.async {
          MainActor.assumeIsolated { self.pending.removeValue(forKey: id)?.resume(throwing: error) }
        }
      }
    }
  }

  /// Fire and forget (acks, input while taking over).
  public func post(_ method: String, _ params: JSONValue = [:], session: String? = nil) {
    Task { _ = try? await send(method, params, session: session) }
  }

  public func close() {
    guard !closed else { return }
    closed = true
    task.cancel(with: .normalClosure, reason: nil)
    fail()
  }

  private func receive() {
    task.receive { result in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          switch result {
          case .failure:
            self.closed = true
            self.fail()
          case .success(let message):
            let text: String
            switch message {
            case .string(let string): text = string
            case .data(let data): text = String(decoding: data, as: UTF8.self)
            @unknown default: text = ""
            }
            self.handle(text)
            if !self.closed { self.receive() }
          }
        }
      }
    }
  }

  private func handle(_ text: String) {
    switch CDPMessage.parse(text) {
    case .response(let id, let result, let error):
      guard let continuation = pending.removeValue(forKey: id) else { return }
      if let error { continuation.resume(throwing: Failure.protocolError(error)) } else { continuation.resume(returning: result ?? [:]) }
    case .event(let method, let params, let session):
      onEvent?(method, params, session)
    case nil:
      break
    }
  }

  private func fail() {
    let waiting = pending
    pending = [:]
    for continuation in waiting.values { continuation.resume(throwing: Failure.closed) }
    let onClose = onClose
    self.onClose = nil
    onClose?()
  }
}
