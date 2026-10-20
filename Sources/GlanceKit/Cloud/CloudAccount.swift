import AppKit
import GlanceCore
import Observation
import SystemConfiguration

/// The Glance account cloud features sign in with (spec 2026-10-18-glance-server-core-design.md, "The Mac app"):
/// Apple, Google or GitHub in a sign-in sheet the Glance server runs, ending on `glance://auth/done`. The session is
/// kept in the Keychain, one per environment; every call to the server goes through `api`.
@MainActor @Observable
public final class CloudAccount {
  public static let shared = CloudAccount()

  public enum State: Equatable {
    case notSetUp
    case signedOut
    case signingIn(CloudProvider)
    case signedIn(CloudUser)
    case failed(String)
  }

  /// A `glance://invite/…` link waiting for "Join" in Settings → Account.
  public struct PendingInvite: Equatable {
    public let token: String
    public let preview: CloudInvitePreview
  }

  public private(set) var state: State = .signedOut
  public private(set) var environment: CloudEnvironment
  /// The account, its sign-in methods and workspaces, as of the last `refreshMe()`.
  public private(set) var me: CloudMe?
  /// What each workspace may use, from the current access token.
  public private(set) var entitlements: [String: Set<String>] = [:]
  public private(set) var pendingInvite: PendingInvite?
  public private(set) var inviteError: String?
  @ObservationIgnored public private(set) var api: CloudClient
  @ObservationIgnored private var sheet: WebSignIn?
  @ObservationIgnored private var signing: Task<CloudUser, Error>?
  @ObservationIgnored private var refresher: Task<Void, Never>?

  private static let defaults = UserDefaults(suiteName: "dev.glance.Glance") ?? .standard
  private static let environmentKey = "cloudEnvironment"

  private init() {
    let environment = CloudEnvironment.current(development: AppVersion.current.isDevelopment,
                                               saved: Self.defaults.string(forKey: Self.environmentKey))
    self.environment = environment
    api = Self.client(for: environment)
    state = Self.state(for: environment)
    entitlements = KeychainSessionStore(environment).load()?.entitlements ?? [:]
    startRefreshing()
    // Signed in from the Keychain: load the account now, so `has(_:)` and Settings don't wait for Settings to open.
    if user != nil { Task { await self.refreshMe() } }
  }

  public var user: CloudUser? {
    if case .signedIn(let user) = state { return user }
    return nil
  }

  /// Whether `feature` is on for `workspace` (the personal one when nil). The server enforces the same claims.
  public func has(_ feature: String, in workspace: String? = nil) -> Bool {
    // Until `me` loads (right after a launch) the token's only workspace is the personal one.
    let id = workspace ?? me?.workspaces.first { $0.kind == .personal }?.id
      ?? (entitlements.count == 1 ? entitlements.keys.first : nil)
    return id.flatMap { entitlements[$0]?.contains(feature) } ?? false
  }

  /// Signs in, or joins the sign-in already under way.
  public func signIn(with provider: CloudProvider) async throws -> CloudUser {
    if let signing { return try await signing.value }
    let task = Task { try await self.runSignIn(provider) }
    signing = task
    defer { signing = nil }
    return try await task.value
  }

  /// Settings → Account → "Link another": the same sheet, adding `provider` to this account. Answers the error to show.
  public func link(_ provider: CloudProvider) async -> String? {
    let environment = environment, api = api
    do {
      guard environment.isSetUp else { throw CloudError.notSetUp }
      let verifier = PKCE.randomToken()
      let ticket = try await api.linkTicket()
      let url = try await sheetURL(CloudAuth.linkURL(environment, provider: provider, ticket: ticket, verifier: verifier))
      switch CloudAuth.callback(url) {
      case .linkCode(let code):
        // Switched environment while the sheet was open: the link belongs to the other one's account.
        guard environment == self.environment else { throw CloudError.cancelled }
        try await api.completeLink(code: code, verifier: verifier)
        await refreshMe()
        return nil
      case .failed(let error):
        throw error
      case .code, .invalid:
        throw CloudError.failed(0)
      }
    } catch {
      let failure = Self.cloudError(error)
      return failure == .cancelled ? nil : failure.message(in: environment.name)
    }
  }

  public func cancelSignIn() {
    sheet?.cancel()
  }

  /// This Mac, or every Mac (`everywhere`).
  public func signOut(everywhere: Bool = false) {
    cancelSignIn()
    // The client forgets the session before it sends the logout, so this never wipes a later sign-in.
    let api = api
    Task { await api.signOut(everywhere: everywhere) }
    me = nil
    entitlements = [:]
    state = environment.isSetUp ? .signedOut : .notSetUp
  }

  /// Reloads the account (Settings opening, after a change).
  public func refreshMe() async {
    guard user != nil else { return }
    let api = api
    guard let fresh = try? await api.me() else { return }
    // Signed out or switched environment while the request was out: that answer is stale.
    guard api === self.api, user != nil, let session = await api.session else { return }
    me = fresh
    state = .signedIn(fresh.user)
    entitlements = session.entitlements
  }

  /// Runs a change on the server, then reloads the account. Answers the error to show, or nil.
  public func run(_ change: @Sendable (CloudClient) async throws -> Void) async -> String? {
    do {
      try await change(api)
      await refreshMe()
      return nil
    } catch {
      return Self.cloudError(error).message(in: environment.name)
    }
  }

  /// A `glance://invite/<token>` link: looks the invite up for Settings → Account to confirm.
  public func openInvite(token: String) async {
    inviteError = nil
    do {
      pendingInvite = PendingInvite(token: token, preview: try await api.invitePreview(token))
    } catch {
      pendingInvite = nil
      inviteError = Self.cloudError(error).message(in: environment.name)
    }
  }

  public func acceptPendingInvite() async -> String? {
    guard let invite = pendingInvite else { return nil }
    let problem = await run { _ = try await $0.acceptInvite(invite.token) }
    if problem == nil { pendingInvite = nil }
    return problem
  }

  public func dismissInvite() {
    pendingInvite = nil
    inviteError = nil
  }

  /// Develop → Cloud: Local / Production. Each environment keeps its own session, so this shows that one's account.
  public func use(_ name: CloudEnvironment.Name) {
    guard AppVersion.current.isDevelopment, name != environment.name else { return }
    cancelSignIn()
    dismissInvite()
    Self.defaults.set(name.rawValue, forKey: Self.environmentKey)
    environment = .named(name)
    api = Self.client(for: environment)
    state = Self.state(for: environment)
    me = nil
    entitlements = KeychainSessionStore(environment).load()?.entitlements ?? [:]
    if user != nil { Task { await self.refreshMe() } }
  }

  /// A request to the Glance server with the account's token. Throws `CloudError`.
  public func authorizedRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    guard environment.isSetUp else { throw CloudError.notSetUp }
    return try await api.authorized(request)
  }

  private func runSignIn(_ provider: CloudProvider) async throws -> CloudUser {
    let environment = environment, api = api
    guard environment.isSetUp else { throw CloudError.notSetUp }
    let before = state
    state = .signingIn(provider)
    do {
      let verifier = PKCE.randomToken()
      let url = try await sheetURL(CloudAuth.startURL(environment, provider: provider, verifier: verifier,
                                                      device: Self.deviceName))
      let session: CloudSession
      switch CloudAuth.callback(url) {
      case .code(let code): session = try await api.exchange(code: code, verifier: verifier)
      case .failed(let error): throw error
      case .linkCode, .invalid: throw CloudError.failed(0)
      }
      // Switched environment while the sheet was open: that sign-in belongs to the other one's Keychain item.
      guard environment == self.environment else { throw CloudError.cancelled }
      state = .signedIn(session.user)
      entitlements = session.entitlements
      await refreshMe()
      return session.user
    } catch {
      let failure = Self.cloudError(error)
      if environment == self.environment {
        // Cancelled (or a second sheet refused) leaves a signed-in account signed in.
        if failure == .cancelled {
          if case .signedIn = before { state = before } else { state = .signedOut }
        } else {
          state = .failed(failure.message(in: environment.name))
        }
      }
      throw failure
    }
  }

  /// One sheet at a time: a second `link`/`signIn` while one is open is cancelled, never orphaning the first.
  private func sheetURL(_ url: URL) async throws -> URL {
    guard sheet == nil else { throw CloudError.cancelled }
    let sheet = WebSignIn()
    self.sheet = sheet
    defer { if self.sheet === sheet { self.sheet = nil } }
    return try await sheet.run(url, scheme: CloudAuth.callbackScheme)
  }

  /// Every minute while signed in: renews the access token near expiry, so entitlements stay current.
  private func startRefreshing() {
    refresher = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(60))
        guard let self else { return }
        guard case .signedIn = self.state else { continue }
        // nil means signed out OR a refresh that failed for a passing reason (offline, 429, 500): ask the client.
        let api = self.api
        _ = await api.refreshIfNeeded()
        guard api === self.api, case .signedIn = self.state, let session = await api.session else { continue }
        self.entitlements = session.entitlements
      }
    }
  }

  /// "Ada's MacBook Pro": what Settings → Your Macs lists.
  static var deviceName: String {
    (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
  }

  private static func cloudError(_ error: Error) -> CloudError {
    (error as? CloudError) ?? .unreachable
  }

  private static func state(for environment: CloudEnvironment) -> State {
    guard environment.isSetUp else { return .notSetUp }
    return KeychainSessionStore(environment).load().map { .signedIn($0.user) } ?? .signedOut
  }

  private static func client(for environment: CloudEnvironment) -> CloudClient {
    let name = environment.name
    return CloudClient(environment: environment, store: KeychainSessionStore(environment), send: { request in
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
      return (data, http)
    }, onSignedOut: {
      Task { @MainActor in CloudAccount.shared.serverSignedOut(name) }
    })
  }

  /// The server ended the session: the next cloud feature asks to sign in again. Can fire more than once, and during
  /// a sign-out the user asked for (its logout refresh may get `session_revoked`): only a signed-in account reacts.
  private func serverSignedOut(_ name: CloudEnvironment.Name) {
    guard name == environment.name, case .signedIn = state else { return }
    state = .signedOut
    me = nil
    entitlements = [:]
  }
}

/// A Glance server session in the Keychain (`glance-server-<environment>`), as JSON.
struct KeychainSessionStore: CloudSessionStore {
  let keychain: KeychainStore

  init(_ environment: CloudEnvironment) {
    keychain = KeychainStore(service: "dev.glance.Glance", account: environment.keychainAccount)
  }

  func load() -> CloudSession? {
    keychain.read().flatMap { try? JSONDecoder().decode(CloudSession.self, from: Data($0.utf8)) }
  }

  func save(_ session: CloudSession?) {
    guard let session, let json = try? JSONEncoder().encode(session) else {
      keychain.delete()
      return
    }
    keychain.save(String(decoding: json, as: UTF8.self))
  }
}
