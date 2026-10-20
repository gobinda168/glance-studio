import Foundation
import Network

/// A fixed loopback port that hands each connection to wherever `route` says, starting things on the first connection:
/// Glance browser keeps the same two ports across launches while its broker only runs when something connects.
@MainActor
final class AgentBrowserRelay {
  enum Target {
    case port(Int)
    /// Answers with a plain HTTP error and closes (Glance browser stopped, no Node…).
    case refuse(String)
  }

  let port: Int
  private let route: () async -> Target
  private var listener: NWListener?
  private var pipes: [ObjectIdentifier: Pipe] = [:]

  var connections: Int { pipes.count }
  var onFailure: ((Error) -> Void)?

  init(port: Int, route: @escaping () async -> Target) {
    self.port = port
    self.route = route
  }

  func start() throws {
    let parameters = NWParameters.tcp
    parameters.requiredInterfaceType = .loopback
    parameters.allowLocalEndpointReuse = true
    let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: UInt16(port))!)
    listener.newConnectionHandler = { connection in
      MainActor.assumeIsolated { self.accept(connection) }
    }
    listener.stateUpdateHandler = { state in
      if case .failed(let error) = state { MainActor.assumeIsolated { self.onFailure?(error) } }
    }
    listener.start(queue: .main)
    self.listener = listener
  }

  /// Ends every open connection (the broker went away); the port keeps listening.
  func dropConnections() {
    for pipe in pipes.values { pipe.close() }
    pipes = [:]
  }

  /// Routes on the first bytes, so a bare connect (a port check) starts nothing.
  private func accept(_ inbound: NWConnection) {
    inbound.start(queue: .main)
    inbound.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, _, _ in
      MainActor.assumeIsolated {
        guard let data, !data.isEmpty else { return inbound.cancel() }
        self.route(inbound, first: data)
      }
    }
  }

  private func route(_ inbound: NWConnection, first: Data) {
    Task { @MainActor [weak self] in
      guard let self else { return inbound.cancel() }
      switch await self.route() {
      case .refuse(let text):
        let body = text + "\n"
        let response = "HTTP/1.1 503 Service Unavailable\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\n"
          + "Connection: close\r\n\r\n" + body
        inbound.send(content: Data(response.utf8), completion: .contentProcessed { _ in inbound.cancel() })
      case .port(let target):
        let outbound = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(target))!, using: .tcp)
        let pipe = Pipe(inbound: inbound, outbound: outbound)
        let key = ObjectIdentifier(pipe)
        self.pipes[key] = pipe
        pipe.onClose = { [weak self] in self?.pipes.removeValue(forKey: key) }
        pipe.start(first: first)
      }
    }
  }

  /// Bytes both ways until either side ends.
  @MainActor
  final class Pipe {
    let inbound: NWConnection
    let outbound: NWConnection
    var onClose: (() -> Void)?
    private var closed = false

    init(inbound: NWConnection, outbound: NWConnection) {
      self.inbound = inbound
      self.outbound = outbound
    }

    /// `first`: what the client sent before the target was known.
    func start(first: Data) {
      outbound.stateUpdateHandler = { state in
        MainActor.assumeIsolated {
          switch state {
          case .failed, .cancelled: self.close()
          default: break
          }
        }
      }
      inbound.stateUpdateHandler = outbound.stateUpdateHandler
      outbound.start(queue: .main)
      outbound.send(content: first, completion: .contentProcessed { error in
        if error != nil { MainActor.assumeIsolated { self.close() } }
      })
      pump(from: inbound, to: outbound)
      pump(from: outbound, to: inbound)
    }

    func close() {
      guard !closed else { return }
      closed = true
      inbound.cancel()
      outbound.cancel()
      onClose?()
      onClose = nil
    }

    private func pump(from source: NWConnection, to destination: NWConnection) {
      source.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
        MainActor.assumeIsolated {
          guard !self.closed else { return }
          if let data, !data.isEmpty {
            destination.send(content: data, completion: .contentProcessed { error in
              if error != nil { MainActor.assumeIsolated { self.close() } }
            })
          }
          if isComplete || error != nil { self.close() } else { self.pump(from: source, to: destination) }
        }
      }
    }
  }
}
