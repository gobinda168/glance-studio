import Foundation
import Testing
@testable import GlanceCore

private let user = CloudUser(id: "u1", email: "ada@example.com", name: "Ada", avatarURL: nil)

final class MemoryStore: CloudSessionStore, @unchecked Sendable {
  private let lock = NSLock()
  private var value: CloudSession?
  init(_ value: CloudSession?) { self.value = value }
  func load() -> CloudSession? { lock.withLock { value } }
  func save(_ session: CloudSession?) { lock.withLock { value = session } }
}

/// A fake Glance server: answers by "METHOD path", records every request, can delay refreshes.
actor FakeServer {
  var requests: [URLRequest] = []
  var answers: [String: [(Int, String)]] = [:]
  var offline = false
  var refreshDelay: Duration = .zero
  var logoutDelay: Duration = .zero

  func answer(_ key: String, _ status: Int, _ body: String) { answers[key, default: []].append((status, body)) }
  func setOffline(_ value: Bool) { offline = value }
  func setRefreshDelay(_ value: Duration) { refreshDelay = value }
  func setLogoutDelay(_ value: Duration) { logoutDelay = value }
  func keys() -> [String] { requests.map { "\($0.httpMethod ?? "GET") \($0.url!.path)" } }

  func handle(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    if offline { throw URLError(.notConnectedToInternet) }
    let key = "\(request.httpMethod ?? "GET") \(request.url!.path)"
    if key == "POST /v1/auth/refresh", refreshDelay != .zero { try await Task.sleep(for: refreshDelay) }
    if key == "POST /v1/auth/logout", logoutDelay != .zero { try await Task.sleep(for: logoutDelay) }
    let queue = answers[key] ?? []
    let (status, body) = queue.first ?? (404, #"{"error":{"code":"not_found","message":"Not found."}}"#)
    if queue.count > 1 { answers[key] = Array(queue.dropFirst()) }
    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
  }
}

func tokenAnswer(_ access: String, _ refresh: String) -> String {
  #"{"access_token":"\#(access)","expires_at":2000000000,"refresh_token":"\#(refresh)","user":{"id":"u1","name":"Ada","email":"ada@example.com","avatar_url":null}}"#
}

func cloudSession(expiresAt: TimeInterval) -> CloudSession {
  CloudSession(accessToken: "old", refreshToken: "r0", expiresAt: Date(timeIntervalSince1970: expiresAt), user: user)
}

func cloudClient(_ server: FakeServer, _ store: MemoryStore, now: TimeInterval = 1_000,
            signedOut: @escaping @Sendable () -> Void = {}) -> CloudClient {
  CloudClient(environment: .local, store: store, send: { try await server.handle($0) },
              now: { Date(timeIntervalSince1970: now) }, onSignedOut: signedOut)
}

@Suite struct CloudClientTests {
  @Test func aFreshSessionSignsTheRequest() async throws {
    let server = FakeServer()
    await server.answer("GET /v1/me", 200, "{}")
    let cloud = cloudClient(server, MemoryStore(cloudSession(expiresAt: 5_000)))
    _ = try await cloud.authorized(CloudAuth.request(.local, "GET", "/v1/me"))
    #expect(await server.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer old")
  }

  @Test func anExpiringSessionRefreshesFirstAndIsSaved() async throws {
    let server = FakeServer()
    await server.answer("POST /v1/auth/refresh", 200, tokenAnswer("new", "r1"))
    await server.answer("GET /v1/me", 200, "{}")
    let store = MemoryStore(cloudSession(expiresAt: 1_030))
    _ = try await cloudClient(server, store).authorized(CloudAuth.request(.local, "GET", "/v1/me"))
    #expect(await server.keys() == ["POST /v1/auth/refresh", "GET /v1/me"])
    #expect(await server.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer new")
    #expect(store.load()?.refreshToken == "r1")
  }

  @Test func a401RefreshesOnceAndRetries() async throws {
    let server = FakeServer()
    await server.answer("GET /v1/me", 401, #"{"error":{"code":"token_expired","message":"m"}}"#)
    await server.answer("GET /v1/me", 200, "{}")
    await server.answer("POST /v1/auth/refresh", 200, tokenAnswer("new", "r1"))
    let (_, response) = try await cloudClient(server, MemoryStore(cloudSession(expiresAt: 5_000)))
      .authorized(CloudAuth.request(.local, "GET", "/v1/me"))
    #expect(response.statusCode == 200)
    #expect(await server.keys() == ["GET /v1/me", "POST /v1/auth/refresh", "GET /v1/me"])
  }

  @Test func concurrentCallersShareOneRefresh() async throws {
    let server = FakeServer()
    await server.setRefreshDelay(.milliseconds(50))
    await server.answer("POST /v1/auth/refresh", 200, tokenAnswer("new", "r1"))
    await server.answer("GET /v1/me", 200, "{}")
    let cloud = cloudClient(server, MemoryStore(cloudSession(expiresAt: 1_010)))
    async let a = cloud.authorized(CloudAuth.request(.local, "GET", "/v1/me"))
    async let b = cloud.authorized(CloudAuth.request(.local, "GET", "/v1/me"))
    _ = try await (a, b)
    #expect(await server.keys().filter { $0 == "POST /v1/auth/refresh" }.count == 1)
  }

  @Test func aRevokedSessionSignsOut() async throws {
    let server = FakeServer()
    await server.answer("POST /v1/auth/refresh", 401, #"{"error":{"code":"session_revoked","message":"m"}}"#)
    let store = MemoryStore(cloudSession(expiresAt: 1_010))
    let signedOut = SignedOutFlag()
    await #expect(throws: CloudError.signedOut) {
      try await cloudClient(server, store, signedOut: { signedOut.set() }).authorized(CloudAuth.request(.local, "GET", "/v1/me"))
    }
    #expect(store.load() == nil && signedOut.value)
  }

  @Test func serverTroubleAndBeingOfflineNeverSignOut() async throws {
    for (status, body) in [(500, #"{"error":{"code":"internal","message":"m"}}"#), (429, #"{"error":{"code":"rate_limited","message":"m"}}"#)] {
      let server = FakeServer()
      await server.answer("POST /v1/auth/refresh", status, body)
      let store = MemoryStore(cloudSession(expiresAt: 1_010))
      await #expect(throws: CloudError.self) {
        try await cloudClient(server, store).authorized(CloudAuth.request(.local, "GET", "/v1/me"))
      }
      #expect(store.load() != nil)
    }
    let server = FakeServer()
    await server.setOffline(true)
    let store = MemoryStore(cloudSession(expiresAt: 1_010))
    await #expect(throws: CloudError.unreachable) {
      try await cloudClient(server, store).authorized(CloudAuth.request(.local, "GET", "/v1/me"))
    }
    #expect(store.load() != nil)
  }

  @Test func exchangeKeepsTheNewSession() async throws {
    let server = FakeServer()
    await server.answer("POST /v1/auth/token", 200, tokenAnswer("a1", "r1"))
    let store = MemoryStore(nil)
    let session = try await cloudClient(server, store).exchange(code: "c", verifier: "v")
    #expect(session.user.name == "Ada" && store.load()?.accessToken == "a1")
  }

  @Test func signOutEverywhereCallsLogoutAllAndForgets() async throws {
    let server = FakeServer()
    await server.answer("POST /v1/auth/logout-all", 204, "")
    let store = MemoryStore(cloudSession(expiresAt: 5_000))
    await cloudClient(server, store).signOut(everywhere: true)
    #expect(await server.keys() == ["POST /v1/auth/logout-all"])
    #expect(store.load() == nil)
  }

  @Test func signOutWithAnExpiredTokenRefreshesFirst() async throws {
    let server = FakeServer()
    await server.answer("POST /v1/auth/refresh", 200, tokenAnswer("new", "r1"))
    await server.answer("POST /v1/auth/logout-all", 204, "")
    let store = MemoryStore(cloudSession(expiresAt: 1_010))
    await cloudClient(server, store).signOut(everywhere: true)
    #expect(await server.keys() == ["POST /v1/auth/refresh", "POST /v1/auth/logout-all"])
    #expect(await server.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer new")
    #expect(store.load() == nil)
  }

  @Test func signOutStillForgetsWhenTheSessionWasRevoked() async throws {
    let server = FakeServer()
    await server.answer("POST /v1/auth/refresh", 401, #"{"error":{"code":"session_revoked","message":"m"}}"#)
    let store = MemoryStore(cloudSession(expiresAt: 1_010))
    await cloudClient(server, store).signOut(everywhere: false)
    #expect(await server.keys() == ["POST /v1/auth/refresh"])
    #expect(store.load() == nil)
  }

  @Test func signOutForgetsWhenOffline() async throws {
    let server = FakeServer()
    await server.setOffline(true)
    let store = MemoryStore(cloudSession(expiresAt: 5_000))
    await cloudClient(server, store).signOut(everywhere: false)
    #expect(store.load() == nil)
  }

  @Test func completeLinkSendsTheCodeAndVerifierSigned() async throws {
    let server = FakeServer()
    await server.answer("POST /v1/auth/link/complete", 204, "")
    try await cloudClient(server, MemoryStore(cloudSession(expiresAt: 5_000))).completeLink(code: "lc", verifier: "v")
    let request = try #require(await server.requests.first)
    #expect(request.httpMethod == "POST" && request.url?.path == "/v1/auth/link/complete")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer old")
    let body = try JSONDecoder().decode([String: String].self, from: try #require(request.httpBody))
    #expect(body == ["code": "lc", "code_verifier": "v"])
  }

  @Test func completeLinkRefusalsSurfaceAsRejected() async throws {
    for (status, code) in [(409, "identity_in_use"), (401, "invalid_code")] {
      let server = FakeServer()
      await server.answer("POST /v1/auth/link/complete", status, #"{"error":{"code":"\#(code)","message":"No."}}"#)
      await #expect(throws: CloudError.rejected(code: code, message: "No.")) {
        try await cloudClient(server, MemoryStore(cloudSession(expiresAt: 5_000))).completeLink(code: "lc", verifier: "v")
      }
    }
  }

  @Test func a401InvalidCodeIsNotRetried() async throws {
    let server = FakeServer()
    await server.answer("POST /v1/auth/link/complete", 401, #"{"error":{"code":"invalid_code","message":"No."}}"#)
    await server.answer("POST /v1/auth/refresh", 200, tokenAnswer("new", "r1"))
    let store = MemoryStore(cloudSession(expiresAt: 5_000))
    await #expect(throws: CloudError.rejected(code: "invalid_code", message: "No.")) {
      try await cloudClient(server, store).completeLink(code: "lc", verifier: "v")
    }
    #expect(await server.keys() == ["POST /v1/auth/link/complete"])
    #expect(store.load()?.accessToken == "old")
  }

  @Test func aRefreshFinishingAfterSignOutDoesNotBringTheSessionBack() async throws {
    let server = FakeServer()
    await server.setRefreshDelay(.milliseconds(150))
    await server.answer("GET /v1/me", 401, #"{"error":{"code":"token_expired","message":"m"}}"#)
    await server.answer("POST /v1/auth/refresh", 200, tokenAnswer("new", "r1"))
    await server.answer("POST /v1/auth/logout", 204, "")
    let store = MemoryStore(cloudSession(expiresAt: 5_000))
    let cloud = cloudClient(server, store)
    let call = Task { try? await cloud.authorized(CloudAuth.request(.local, "GET", "/v1/me")) }
    try await Task.sleep(for: .milliseconds(40))
    await cloud.signOut(everywhere: false)
    _ = await call.value
    #expect(store.load() == nil)
    #expect(await cloud.session == nil)
  }

  @Test func aSlowLogoutDoesNotWipeANewSignIn() async throws {
    let server = FakeServer()
    await server.setLogoutDelay(.milliseconds(150))
    await server.answer("POST /v1/auth/logout", 204, "")
    await server.answer("POST /v1/auth/token", 200, tokenAnswer("a9", "r9"))
    let store = MemoryStore(cloudSession(expiresAt: 5_000))
    let cloud = cloudClient(server, store)
    let out = Task { await cloud.signOut(everywhere: false) }
    try await Task.sleep(for: .milliseconds(40))
    #expect(store.load() == nil)
    _ = try await cloud.exchange(code: "c", verifier: "v")
    await out.value
    #expect(store.load()?.accessToken == "a9")
    #expect(await cloud.session?.refreshToken == "r9")
  }

  @Test func aSignInDuringSignOutsRefreshIsNotWiped() async throws {
    let server = FakeServer()
    await server.setRefreshDelay(.milliseconds(150))
    await server.answer("POST /v1/auth/refresh", 200, tokenAnswer("stale", "r1"))
    await server.answer("POST /v1/auth/token", 200, tokenAnswer("a9", "r9"))
    await server.answer("POST /v1/auth/logout", 204, "")
    let store = MemoryStore(cloudSession(expiresAt: 1_010))
    let cloud = cloudClient(server, store)
    let out = Task { await cloud.signOut(everywhere: false) }
    try await Task.sleep(for: .milliseconds(40))
    _ = try await cloud.exchange(code: "c", verifier: "v")
    await out.value
    #expect(store.load()?.accessToken == "a9")
    #expect(await server.keys().contains("POST /v1/auth/logout") == false)
  }

  @Test func aRefreshFinishingAfterANewSignInDoesNotOverwriteIt() async throws {
    let server = FakeServer()
    await server.setRefreshDelay(.milliseconds(150))
    await server.answer("GET /v1/me", 401, #"{"error":{"code":"token_expired","message":"m"}}"#)
    await server.answer("GET /v1/me", 200, "{}")
    await server.answer("POST /v1/auth/refresh", 200, tokenAnswer("stale", "r1"))
    await server.answer("POST /v1/auth/token", 200, tokenAnswer("a9", "r9"))
    let store = MemoryStore(cloudSession(expiresAt: 5_000))
    let cloud = cloudClient(server, store)
    let call = Task { try? await cloud.authorized(CloudAuth.request(.local, "GET", "/v1/me")) }
    try await Task.sleep(for: .milliseconds(40))
    _ = try await cloud.exchange(code: "c", verifier: "v")
    _ = await call.value
    #expect(store.load()?.accessToken == "a9" && store.load()?.refreshToken == "r9")
    #expect(await cloud.session?.accessToken == "a9")
  }

  @Test func aSecond401AfterTheRetryIsTheAnswerAndKeepsTheSession() async throws {
    let server = FakeServer()
    await server.answer("GET /v1/me", 401, #"{"error":{"code":"token_expired","message":"m"}}"#)
    await server.answer("GET /v1/me", 401, #"{"error":{"code":"forbidden","message":"Nope."}}"#)
    await server.answer("POST /v1/auth/refresh", 200, tokenAnswer("new", "r1"))
    let store = MemoryStore(cloudSession(expiresAt: 5_000))
    await #expect(throws: CloudError.rejected(code: "forbidden", message: "Nope.")) {
      try await cloudClient(server, store).callEmpty("GET", "/v1/me")
    }
    #expect(await server.keys() == ["GET /v1/me", "POST /v1/auth/refresh", "GET /v1/me"])
    #expect(store.load()?.accessToken == "new")
  }

  @Test func refreshIfNeededOnlyRefreshesNearExpiry() async throws {
    let server = FakeServer()
    await server.answer("POST /v1/auth/refresh", 200, tokenAnswer("new", "r1"))
    #expect(await cloudClient(server, MemoryStore(cloudSession(expiresAt: 5_000))).refreshIfNeeded()?.accessToken == "old")
    #expect(await cloudClient(server, MemoryStore(cloudSession(expiresAt: 1_020))).refreshIfNeeded()?.accessToken == "new")
    #expect(await cloudClient(server, MemoryStore(nil)).refreshIfNeeded() == nil)
  }
}

final class SignedOutFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var flag = false
  func set() { lock.withLock { flag = true } }
  var value: Bool { lock.withLock { flag } }
}
