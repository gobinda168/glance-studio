import Foundation

/// How Glance signs in to the Glance server (spec 2026-10-18-glance-server-core-design.md, "Sign-in"): the server runs
/// Apple, Google and GitHub sign-in in a sign-in sheet and ends it on `glance://auth/done` with a one-time code, which
/// the app trades, with its PKCE verifier, for tokens. The sheet is GlanceKit's CloudAccount; the calls, CloudClient.
public enum CloudProvider: String, CaseIterable, Codable, Sendable {
  case apple, google, github

  public var title: String {
    switch self {
    case .apple: "Apple"
    case .google: "Google"
    case .github: "GitHub"
    }
  }
}

public struct CloudUser: Codable, Equatable, Sendable {
  public var id: String
  public var email: String?
  public var name: String?
  public var avatarURL: URL?

  enum CodingKeys: String, CodingKey {
    case id, email, name
    case avatarURL = "avatar_url"
  }

  public init(id: String, email: String?, name: String?, avatarURL: URL?) {
    self.id = id
    self.email = email
    self.name = name
    self.avatarURL = avatarURL
  }

  /// The name, else the email: one line in Settings.
  public var displayName: String {
    [name, email].compactMap { $0 }.first { !$0.isEmpty } ?? "Glance account"
  }
}

public struct CloudSession: Codable, Equatable, Sendable {
  public var accessToken: String
  public var refreshToken: String
  public var expiresAt: Date
  public var user: CloudUser

  public init(accessToken: String, refreshToken: String, expiresAt: Date, user: CloudUser) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expiresAt = expiresAt
    self.user = user
  }

  /// Within a minute of expiring.
  public func needsRefresh(now: Date) -> Bool { expiresAt.timeIntervalSince(now) < 60 }

  /// What each workspace may use, from the access token (the server checks the same claims).
  public var entitlements: [String: Set<String>] { CloudAuth.entitlements(accessToken: accessToken) }
}

public enum CloudError: Error, Equatable, Sendable {
  case notSetUp
  /// No session, or the server ended it: sign in again.
  case signedOut
  case cancelled
  case timedOut
  /// No answer from the server (offline, or the local server isn't running). Never signs out.
  case unreachable
  /// The server said no: its error code and a sentence for people.
  case rejected(code: String, message: String)
  case failed(Int)

  public var code: String? {
    if case .rejected(let code, _) = self { code } else { nil }
  }

  /// Only these answers to a refresh mean the session is over.
  public var endsSession: Bool { code == "session_revoked" || code == "unauthenticated" }

  public func message(in environment: CloudEnvironment.Name) -> String {
    switch self {
    case .notSetUp: "The Glance server isn't set up in this build."
    case .signedOut: "Signed out. Sign in again to use cloud features."
    case .cancelled: "Sign-in was cancelled."
    case .timedOut: "Sign-in didn't finish. Try again."
    case .unreachable:
      environment == .local ? "Can't reach the local Glance server. Run `docker compose --profile server up` in ~/Code/glance-server."
        : "Can't reach the Glance server. Check your connection."
    case .rejected(_, let message): message
    case .failed(let status): "The Glance server answered \(status). Try again."
    }
  }
}

public enum CloudAuth {
  /// The sheet ends on `glance://auth/done`; invites arrive as `glance://invite/<token>`.
  public static let callbackScheme = "glance"

  public static func startURL(_ environment: CloudEnvironment, provider: CloudProvider, verifier: String,
                              device: String) throws -> URL {
    try url(environment, "/v1/auth/\(provider.rawValue)/start",
            ["code_challenge": PKCE.challenge(for: verifier), "device": device])
  }

  /// "Link another": the same sheet with a ticket from `POST /v1/auth/link` and a PKCE challenge; the sheet ends with a
  /// `link_code` the app completes with `linkCompleteRequest`.
  public static func linkURL(_ environment: CloudEnvironment, provider: CloudProvider, ticket: String,
                             verifier: String) throws -> URL {
    try url(environment, "/v1/auth/\(provider.rawValue)/start",
            ["code_challenge": PKCE.challenge(for: verifier), "link_ticket": ticket])
  }

  public enum Callback: Equatable, Sendable {
    case code(String)
    case linkCode(String)
    case failed(CloudError)
    case invalid
  }

  /// What `glance://auth/done?…` means.
  public static func callback(_ url: URL) -> Callback {
    guard url.scheme == callbackScheme, url.host == "auth", url.path == "/done" else { return .invalid }
    var items: [String: String] = [:]
    for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] where items[item.name] == nil {
      items[item.name] = item.value ?? ""
    }
    if let error = items["error"] { return .failed(signInError(error)) }
    if let code = items["link_code"], !code.isEmpty { return .linkCode(code) }
    if let code = items["code"], !code.isEmpty { return .code(code) }
    return .invalid
  }

  /// The token of `glance://invite/<43 base64url characters>`, else nil.
  public static func inviteToken(from url: URL) -> String? {
    guard url.scheme == callbackScheme, url.host == "invite" else { return nil }
    let parts = url.pathComponents.filter { $0 != "/" }
    guard parts.count == 1, let token = parts.first, token.count == 43,
          token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
    else { return nil }
    return token
  }

  static func signInError(_ code: String) -> CloudError {
    switch code {
    case "cancelled": .cancelled
    case "expired": .rejected(code: code, message: "Sign-in took too long. Try again.")
    case "identity_in_use": .rejected(code: code, message: "That sign-in already belongs to another Glance account.")
    default: .rejected(code: code, message: "Sign-in didn't work. Try again.")
    }
  }

  public static func tokenRequest(_ environment: CloudEnvironment, code: String, verifier: String) throws -> URLRequest {
    try request(environment, "POST", "/v1/auth/token", ["code": code, "code_verifier": verifier])
  }

  public static func appleRequest(_ environment: CloudEnvironment, identityToken: String, nonce: String, name: String?,
                                  device: String) throws -> URLRequest {
    var body = ["identity_token": identityToken, "nonce": nonce, "device": device]
    if let name, !name.isEmpty { body["name"] = name }
    return try request(environment, "POST", "/v1/auth/apple", body)
  }

  public static func refreshRequest(_ environment: CloudEnvironment, refreshToken: String) throws -> URLRequest {
    try request(environment, "POST", "/v1/auth/refresh", ["refresh_token": refreshToken])
  }

  /// Finishes "Link another": trades the sheet's `link_code` and the PKCE verifier. The client adds the access token.
  public static func linkCompleteRequest(_ environment: CloudEnvironment, code: String, verifier: String) throws -> URLRequest {
    try request(environment, "POST", "/v1/auth/link/complete", ["code": code, "code_verifier": verifier])
  }

  /// Unsigned: the client sends it through its signed path.
  public static func logoutRequest(_ environment: CloudEnvironment, everywhere: Bool) throws -> URLRequest {
    try request(environment, "POST", everywhere ? "/v1/auth/logout-all" : "/v1/auth/logout")
  }

  /// `method path` on the server, with `body` as JSON when given.
  public static func request(_ environment: CloudEnvironment, _ method: String, _ path: String,
                             _ body: [String: String]? = nil) throws -> URLRequest {
    guard let url = environment.url(path) else { throw CloudError.notSetUp }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 15
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONEncoder().encode(body)
    }
    return request
  }

  /// `request` with the session's access token.
  public static func signed(_ request: URLRequest, session: CloudSession) -> URLRequest {
    var request = request
    request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
    return request
  }

  /// A sign-in or refresh answer.
  public static func session(from data: Data, status: Int) throws -> CloudSession {
    guard status == 200 else { throw error(from: data, status: status) }
    struct Answer: Decodable {
      let accessToken: String
      let expiresAt: Double
      let refreshToken: String
      let user: CloudUser

      enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", expiresAt = "expires_at", refreshToken = "refresh_token", user
      }
    }
    guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else { throw CloudError.failed(status) }
    return CloudSession(accessToken: answer.accessToken, refreshToken: answer.refreshToken,
                        expiresAt: Date(timeIntervalSince1970: answer.expiresAt), user: answer.user)
  }

  /// The server's `{"error": {"code", "message"}}`, else the bare status.
  public static func error(from data: Data, status: Int) -> CloudError {
    struct Body: Decodable {
      struct Detail: Decodable {
        let code: String
        let message: String
      }

      let error: Detail
    }
    guard let body = try? JSONDecoder().decode(Body.self, from: data) else { return .failed(status) }
    return .rejected(code: body.error.code, message: body.error.message)
  }

  /// The access token's `ent` claim: workspace ID → features. Unreadable means none.
  public static func entitlements(accessToken: String) -> [String: Set<String>] {
    let parts = accessToken.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return [:] }
    var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while base64.count % 4 != 0 { base64 += "=" }
    struct Claims: Decodable { let ent: [String: [String]]? }
    guard let data = Data(base64Encoded: base64), let claims = try? JSONDecoder().decode(Claims.self, from: data)
    else { return [:] }
    return (claims.ent ?? [:]).mapValues(Set.init)
  }

  private static func url(_ environment: CloudEnvironment, _ path: String, _ query: [String: String]) throws -> URL {
    guard let base = environment.url(path), var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
    else { throw CloudError.notSetUp }
    components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
    // URLComponents leaves "+" raw, and the server's form decoding reads a raw "+" as a space.
    components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    guard let url = components.url else { throw CloudError.notSetUp }
    return url
  }
}
