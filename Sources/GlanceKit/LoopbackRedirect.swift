import Foundation
import GlanceCore
import Network

/// One browser sign-in's way back (Google's and Glance Cloud's): a listener on 127.0.0.1 on a port the system picks.
/// `classify` reads each request's path: the code, a failure to show, or something to ignore (a favicon, a stale tab),
/// which gets a 404 while the wait goes on. One instance per sign-in.
@MainActor
public final class LoopbackRedirect {
  public enum Answer: Equatable {
    case code(String)
    /// Shown as the tab's title, and thrown as `Failure.failed`.
    case failed(String)
    case ignore
  }

  public enum Failure: Error, Equatable {
    case cancelled
    case timedOut
    case failed(String)
  }

  private var listener: NWListener?
  private var waiting: CheckedContinuation<String, Error>?
  /// The answer, when it came before anyone waited for it.
  private var early: Result<String, Error>?
  private var done = false
  private var timer: Task<Void, Never>?

  public init() {}

  /// Listens; returns the port once ready.
  public func start(classify: @escaping @MainActor (String) -> Answer) async throws -> UInt16 {
    let parameters = NWParameters.tcp
    parameters.requiredInterfaceType = .loopback
    let listener = try NWListener(using: parameters, on: .any)
    listener.newConnectionHandler = { [weak self] connection in
      MainActor.assumeIsolated { self?.serve(connection, classify: classify) }
    }
    self.listener = listener
    let once = Once()
    return try await withCheckedThrowingContinuation { (ready: CheckedContinuation<UInt16, Error>) in
      listener.stateUpdateHandler = { update in
        MainActor.assumeIsolated {
          switch update {
          case .ready: once.run { ready.resume(returning: listener.port?.rawValue ?? 0) }
          case .failed(let error): once.run { ready.resume(throwing: error) }
          case .cancelled: once.run { ready.resume(throwing: Failure.cancelled) }
          default: break
          }
        }
      }
      listener.start(queue: .main)
    }
  }

  /// The code from the browser, or `Failure.timedOut` after `limit`.
  public func code(within limit: Duration) async throws -> String {
    if let early { return try early.get() }
    return try await withCheckedThrowingContinuation { continuation in
      waiting = continuation
      timer = Task { @MainActor [weak self] in
        try? await Task.sleep(for: limit)
        guard !Task.isCancelled else { return }
        self?.finish(.failure(Failure.timedOut))
      }
    }
  }

  public func cancel() {
    finish(.failure(Failure.cancelled))
  }

  private func finish(_ result: Result<String, Error>) {
    guard !done else { return }
    done = true
    timer?.cancel()
    listener?.cancel()
    listener = nil
    if let waiting {
      self.waiting = nil
      waiting.resume(with: result)
    } else {
      early = result
    }
  }

  private func serve(_ connection: NWConnection, classify: @escaping @MainActor (String) -> Answer) {
    connection.start(queue: .main)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
      MainActor.assumeIsolated {
        guard let self, let data, case .complete(let request) = HTTPRequest.parse(data) else {
          connection.cancel()
          return
        }
        switch classify(request.path) {
        case .code(let code):
          self.reply(connection, 200, LoopbackPage.html(title: "Signed in to Glance", line: "You can close this tab."))
          self.finish(.success(code))
        case .failed(let message):
          self.reply(connection, 200, LoopbackPage.html(title: message, line: "You can close this tab."))
          self.finish(.failure(Failure.failed(message)))
        case .ignore:
          self.reply(connection, 404, "")
        }
      }
    }
  }

  private func reply(_ connection: NWConnection, _ status: Int, _ html: String) {
    let response = HTTPRequest.response(status: status, reason: status == 200 ? "OK" : "Not Found", body: html,
                                        contentType: "text/html; charset=utf-8")
    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
  }

  /// Resumes a continuation once: the listener can report ready, then cancelled.
  @MainActor private final class Once {
    private var done = false

    func run(_ body: () -> Void) {
      guard !done else { return }
      done = true
      body()
    }
  }
}
