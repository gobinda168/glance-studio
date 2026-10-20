import Foundation
import Testing
@testable import GlanceCore

/// URLSessionSecretTransport against a URLProtocol stub: no network.
@Suite(.serialized) struct SecretTransportTests {
  final class Stub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var chunksSent = 0
    static let lock = NSLock()
    static let chunk = Data(repeating: 0x61, count: 1_048_576)
    private var stopped = false

    static func reset() { lock.withLock { chunksSent = 0 } }
    static var sent: Int { lock.withLock { chunksSent } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
      let url = request.url!
      func respond(_ status: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
      }
      switch url.path {
      case "/stream":
        // 30 MB with no Content-Length, one chunk at a time until the client stops listening.
        client?.urlProtocol(self, didReceive: respond(200), cacheStoragePolicy: .notAllowed)
        DispatchQueue.global().async { self.pump(left: 30) }
      case "/declared":
        client?.urlProtocol(self, didReceive: respond(200, ["Content-Length": "31457280"]), cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("x".utf8))
        client?.urlProtocolDidFinishLoading(self)
      case "/away", "/hop":
        let to = url.path == "/away" ? "https://evil.example/stolen" : "https://api.example/hop"
        let response = respond(302, ["Location": to])
        client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: to)!), redirectResponse: response)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("moved".utf8))
        client?.urlProtocolDidFinishLoading(self)
      default:
        client?.urlProtocol(self, didReceive: respond(200, ["X-Auth": request.value(forHTTPHeaderField: "Authorization") ?? ""]),
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("ok".utf8))
        client?.urlProtocolDidFinishLoading(self)
      }
    }

    private func pump(left: Int) {
      Self.lock.lock()
      let stop = stopped || left == 0
      if !stop { Self.chunksSent += 1 }
      Self.lock.unlock()
      if left == 0 { client?.urlProtocolDidFinishLoading(self) }
      guard !stop else { return }
      client?.urlProtocol(self, didLoad: Self.chunk)
      DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(5)) { self.pump(left: left - 1) }
    }

    override func stopLoading() {
      Self.lock.lock()
      stopped = true
      Self.lock.unlock()
    }
  }

  let transport = URLSessionSecretTransport(protocolClasses: [Stub.self])

  func request(_ path: String) -> URLRequest {
    var request = URLRequest(url: URL(string: "https://api.example\(path)")!)
    request.setValue("Bearer v", forHTTPHeaderField: "Authorization")
    return request
  }

  @Test func aSmallResponseComesBack() async throws {
    let (response, data) = try await transport.send(request("/ok"), maxBytes: 100) { _ in true }
    #expect(response.statusCode == 200)
    #expect(response.value(forHTTPHeaderField: "X-Auth") == "Bearer v")
    #expect(data == Data("ok".utf8))
  }

  @Test func aStreamStopsOnceItPassesTheCap() async throws {
    Stub.reset()
    await #expect(throws: SecretTransportError.tooLarge) {
      _ = try await transport.send(request("/stream"), maxBytes: 3 * 1_048_576) { _ in true }
    }
    try await Task.sleep(for: .milliseconds(100))
    #expect(Stub.sent < 10)
  }

  @Test func aDeclaredLengthOverTheCapIsRefusedUpFront() async {
    await #expect(throws: SecretTransportError.tooLarge) {
      _ = try await transport.send(request("/declared"), maxBytes: 1_048_576) { _ in true }
    }
  }

  @Test func aRedirectFollowRefusesComesBackAsTheResponse() async throws {
    let asked = Asked()
    let (response, _) = try await transport.send(request("/away"), maxBytes: 100) { url in
      asked.add(url)
      return false
    }
    #expect(response.statusCode == 302)
    #expect(response.value(forHTTPHeaderField: "Location") == "https://evil.example/stolen")
    #expect(asked.urls == [URL(string: "https://evil.example/stolen")!])
  }

  @Test func atMostFiveRedirectsAreFollowed() async throws {
    let asked = Asked()
    let (response, _) = try await transport.send(request("/hop"), maxBytes: 100) { url in
      asked.add(url)
      return true
    }
    #expect(response.statusCode == 302)
    #expect(asked.urls.count == 5)
  }

  final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [URL] = []
    func add(_ url: URL) { lock.withLock { all.append(url) } }
    var urls: [URL] { lock.withLock { all } }
  }
}
