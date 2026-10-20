import Foundation

/// Where a Glance server session is kept between launches (GlanceKit: the Keychain). nil deletes it.
public protocol CloudSessionStore: Sendable {
  func load() -> CloudSession?
  func save(_ session: CloudSession?)
}

/// Every call to the Glance server goes through here (spec 2026-10-18-glance-server-core-design.md, "The Mac app"):
/// - Adds the access token, refreshing first when it has under a minute left.
/// - A 401 refreshes once and retries once.
/// - Concurrent callers share one refresh: the server rotates refresh tokens and ends the session if an old one comes
///   back, so a second refresh with the same token would sign the user out.
/// - Only `session_revoked`/`unauthenticated` from a refresh signs out; offline, rate limits and server errors never do.
public actor CloudClient {
  public typealias Send = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

  public let environment: CloudEnvironment
  public private(set) var session: CloudSession?
  private let store: any CloudSessionStore
  private let send: Send
  private let now: @Sendable () -> Date
  private let onSignedOut: @Sendable () -> Void
  private var refreshing: Task<CloudSession, Error>?
  /// Counts sheet/Apple sign-ins, so a sign-out can tell a new sign-in from its own refresh.
  private var signIns = 0

  public init(environment: CloudEnvironment, store: any CloudSessionStore, send: @escaping Send,
              now: @escaping @Sendable () -> Date = { Date() }, onSignedOut: @escaping @Sendable () -> Void = {}) {
    self.environment = environment
    self.store = store
    self.send = send
    self.now = now
    self.onSignedOut = onSignedOut
    session = store.load()
  }

  /// The end of a sheet sign-in: the one-time code and the PKCE verifier for a session, kept.
  public func exchange(code: String, verifier: String) async throws -> CloudSession {
    let new = try await token(CloudAuth.tokenRequest(environment, code: code, verifier: verifier))
    signIns += 1
    keep(new)
    return new
  }

  /// Native Sign in with Apple: Apple's identity token and the raw nonce for a session, kept.
  public func signInWithApple(identityToken: String, nonce: String, name: String?, device: String) async throws -> CloudSession {
    let new = try await token(CloudAuth.appleRequest(environment, identityToken: identityToken, nonce: nonce,
                                                     name: name, device: device))
    signIns += 1
    keep(new)
    return new
  }

  /// Signs `request` in and sends it. A 401 refreshes once and retries once, except `invalid_code`: that is the answer
  /// to a burned one-time code (link completion), not a stale token, and replaying the code is never safe.
  public func authorized(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    guard environment.isSetUp else { throw CloudError.notSetUp }
    guard var current = session else { throw CloudError.signedOut }
    if current.needsRefresh(now: now()) { current = try await refresh() }
    let answer = try await transmit(CloudAuth.signed(request, session: current))
    guard answer.1.statusCode == 401 else { return answer }
    if CloudAuth.error(from: answer.0, status: 401).code == "invalid_code" { return answer }
    let renewed = try await refresh()
    return try await transmit(CloudAuth.signed(request, session: renewed))
  }

  /// Renews the access token when it has under a minute left (the account's timer), so entitlements stay current.
  public func refreshIfNeeded() async -> CloudSession? {
    guard let current = session else { return nil }
    guard current.needsRefresh(now: now()) else { return current }
    return try? await refresh()
  }

  /// Forgets the session here and tells the server (best effort): this Mac, or every Mac. An expired access token is
  /// refreshed first. The session is forgotten BEFORE the logout goes out, so a slow logout can never wipe a sign-in
  /// that started meanwhile; if the session changed under us (a new sign-in), it is left alone.
  public func signOut(everywhere: Bool = false) async {
    guard var current = session else { return }
    let signInsBefore = signIns
    if current.needsRefresh(now: now()), let renewed = try? await refresh() { current = renewed }
    // A sign-in during the refresh, or a session that is no longer the one we hold, is not ours to end.
    guard signIns == signInsBefore, session?.refreshToken == current.refreshToken else { return }
    keep(nil)
    if let request = try? CloudAuth.logoutRequest(environment, everywhere: everywhere) {
      _ = try? await transmit(CloudAuth.signed(request, session: current))
    }
  }

  /// Finishes "Link another": trades the sheet's `link_code` and the PKCE verifier for a linked sign-in. A refusal
  /// (`invalid_code`, `identity_in_use`) throws `CloudError.rejected`.
  public func completeLink(code: String, verifier: String) async throws {
    try await callEmpty("POST", "/v1/auth/link/complete", ["code": code, "code_verifier": verifier])
  }

  /// `method path` signed in, decoded as `T`. A refusal throws `CloudError.rejected` with the server's code.
  public func call<T: Decodable>(_ method: String, _ path: String, _ body: [String: String]? = nil) async throws -> T {
    let (data, response) = try await authorized(CloudAuth.request(environment, method, path, body))
    return try decode(data, response)
  }

  /// `method path` signed in, answer ignored.
  public func callEmpty(_ method: String, _ path: String, _ body: [String: String]? = nil) async throws {
    let (data, response) = try await authorized(CloudAuth.request(environment, method, path, body))
    guard (200..<300).contains(response.statusCode) else { throw CloudAuth.error(from: data, status: response.statusCode) }
  }

  /// `method path` without the session (invite previews).
  public func callUnsigned<T: Decodable>(_ method: String, _ path: String) async throws -> T {
    let (data, response) = try await transmit(CloudAuth.request(environment, method, path))
    return try decode(data, response)
  }

  private func decode<T: Decodable>(_ data: Data, _ response: HTTPURLResponse) throws -> T {
    guard (200..<300).contains(response.statusCode) else { throw CloudAuth.error(from: data, status: response.statusCode) }
    do {
      return try CloudAPI.decoder.decode(T.self, from: data)
    } catch {
      throw CloudError.failed(response.statusCode)
    }
  }

  private func refresh() async throws -> CloudSession {
    if let refreshing { return try await refreshing.value }
    let task = Task { try await self.runRefresh() }
    refreshing = task
    defer { refreshing = nil }
    return try await task.value
  }

  /// The refresh only counts while the session it started from is still the current one: if the user signed out, or
  /// signed in again, while it was in flight, its answer is dropped and the store is left alone.
  private func runRefresh() async throws -> CloudSession {
    guard let old = session else { throw CloudError.signedOut }
    do {
      let new = try await token(CloudAuth.refreshRequest(environment, refreshToken: old.refreshToken))
      guard session?.refreshToken == old.refreshToken else { return try superseded() }
      keep(new)
      return new
    } catch let error as CloudError where error.endsSession {
      guard session?.refreshToken == old.refreshToken else { return try superseded() }
      keep(nil)
      onSignedOut()
      throw CloudError.signedOut
    }
  }

  /// A refresh that lost to a sign-out (no session: signed out) or to a new sign-in (that session stands).
  private func superseded() throws -> CloudSession {
    guard let session else { throw CloudError.signedOut }
    return session
  }

  private func token(_ request: URLRequest) async throws -> CloudSession {
    let (data, response) = try await transmit(request)
    return try CloudAuth.session(from: data, status: response.statusCode)
  }

  private func transmit(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    do {
      return try await send(request)
    } catch is URLError {
      throw CloudError.unreachable
    }
  }

  private func keep(_ new: CloudSession?) {
    session = new
    store.save(new)
  }
}
