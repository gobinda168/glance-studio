import Foundation
import GlanceCore
import Network

/// Receives Claude Code hook events from `hooks/notify.sh` on 127.0.0.1, and glance-replies' previews. The host app
/// runs it for as long as it runs, so previews work with the overlay switched off.
@MainActor
public final class EventServer {
  public static let defaultPort: UInt16 = 47823

  public var onEvent: ((HookEvent) -> Void)?
  /// `POST /preview {"path": …}`: show that file over the window (glance-replies' image captions). False when no
  /// window can show it.
  public var onPreview: ((String) -> Bool)?
  /// Called if the port can't be bound (usually: Glance is already running).
  public var onFailure: ((Error) -> Void)?
  private var listener: NWListener?

  public init() {}

  public func start(port: UInt16) throws {
    let parameters = NWParameters.tcp
    parameters.requiredInterfaceType = .loopback
    parameters.allowLocalEndpointReuse = true
    let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
    listener.newConnectionHandler = { connection in
      MainActor.assumeIsolated { self.serve(connection) }
    }
    listener.stateUpdateHandler = { state in
      if case .failed(let error) = state { MainActor.assumeIsolated { self.onFailure?(error) } }
    }
    listener.start(queue: .main)
    self.listener = listener
  }

  public func stop() {
    listener?.cancel()
    listener = nil
  }

  private func serve(_ connection: NWConnection) {
    connection.start(queue: .main)
    receive(connection, buffer: Data())
  }

  private func receive(_ connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
      MainActor.assumeIsolated {
        var buffer = buffer
        if let data { buffer.append(data) }
        switch HTTPRequest.parse(buffer) {
        case .incomplete:
          if isComplete || error != nil { connection.cancel() } else { self.receive(connection, buffer: buffer) }
        case .invalid:
          self.respond(connection, 400, "Bad Request")
        case .complete(let request):
          let (status, reason) = self.route(request)
          self.respond(connection, status, reason)
        }
      }
    }
  }

  private func route(_ request: HTTPRequest) -> (Int, String) {
    // Browsers attach Origin; hooks (curl) don't. Refuse anything a web page could send.
    if request.headers["origin"] != nil { return (403, "Forbidden") }
    switch (request.method, request.path) {
    case ("GET", "/health"):
      return (200, "OK")
    case ("POST", "/preview"):
      guard let path = FilePreview.requestedPath(request.body) else { return (400, "Bad Request") }
      return onPreview?(path) == true ? (202, "Accepted") : (503, "Unavailable")
    case ("POST", "/event"):
      guard let event = try? JSONDecoder().decode(HookEvent.self, from: request.body) else { return (400, "Bad Request") }
      onEvent?(event)
      return (202, "Accepted")
    default:
      return (404, "Not Found")
    }
  }

  private func respond(_ connection: NWConnection, _ status: Int, _ reason: String) {
    connection.send(content: HTTPRequest.response(status: status, reason: reason, body: reason + "\n"),
                    completion: .contentProcessed { _ in connection.cancel() })
  }
}
