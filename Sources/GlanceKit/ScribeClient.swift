import Foundation
import GlanceCore

/// One Scribe v2 Realtime session. Audio sent before `session_started` is queued and flushed in order.
@MainActor
final class ScribeClient {
  var onEvent: ((ScribeEvent) -> Void)?
  /// Every text frame from the server, for `glance transcribe`.
  var onRawMessage: ((String) -> Void)?
  private(set) var hasStarted = false

  private let request: URLRequest
  private let previousText: String?
  private var task: URLSessionWebSocketTask?
  private var queued: [String] = []
  private var sentFirst = false

  init(key: String, keyterms: [String], zeroRetention: Bool, previousText: String?) {
    var request = URLRequest(url: ScribeMessages.url(keyterms: keyterms, zeroRetention: zeroRetention))
    request.setValue(key, forHTTPHeaderField: "xi-api-key")
    self.request = request
    self.previousText = previousText
  }

  func connect() {
    let task = URLSession.shared.webSocketTask(with: request)
    self.task = task
    task.resume()
    receive(on: task)
  }

  func send(audio: Data, commit: Bool = false) {
    let message = ScribeMessages.audioChunk(audio, commit: commit, previousText: sentFirst ? nil : previousText)
    sentFirst = true
    if hasStarted { transmit(message) } else { queued.append(message) }
  }

  /// Closes the socket; no events are delivered afterwards.
  func close() {
    task?.cancel(with: .normalClosure, reason: nil)
    task = nil
    onEvent = nil
    onRawMessage = nil
  }

  private func transmit(_ message: String) {
    task?.send(.string(message)) { [weak self] error in
      guard let error else { return }
      Task { @MainActor in self?.failed(error) }
    }
  }

  private func receive(on task: URLSessionWebSocketTask) {
    task.receive { [weak self] result in
      Task { @MainActor in
        guard let self, self.task === task else { return }
        switch result {
        case .failure(let error):
          self.failed(error)
        case .success(.string(let text)):
          self.handle(text)
          self.receive(on: task)
        case .success:
          self.receive(on: task)
        }
      }
    }
  }

  private func handle(_ text: String) {
    onRawMessage?(text)
    guard let event = ScribeMessages.decode(text) else { return }
    if event == .started {
      hasStarted = true
      queued.forEach(transmit)
      queued.removeAll()
    }
    onEvent?(event)
  }

  private func failed(_ error: Error) {
    guard let task else { return }
    let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
    self.task = nil
    let event: ScribeEvent = switch status {
    case 401: .failure(kind: "auth_error", message: "HTTP 401")
    case 400...: .failure(kind: "http", message: "HTTP \(status)")
    default: .failure(kind: "network", message: error.localizedDescription)
    }
    onEvent?(event)
  }
}
