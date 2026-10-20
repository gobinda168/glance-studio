import Foundation

/// Glance's OAuth client, a "Desktop app" client in the user's Google Cloud project (spec
/// 2026-10-09-meeting-decline-rsvp-design.md, "The user's setup"). Google treats a desktop client's secret as public,
/// so both ship in the app. Empty means Google sign-in isn't set up in this build.
public enum GoogleClient {
  public static let id = ""
  public static let secret = ""
  public static var isSetUp: Bool { !id.isEmpty }
}

/// Signing in to Google from a desktop app (spec "GoogleAuth"): PKCE, the consent page in the browser, the loopback
/// callback, and the token endpoint's answers. The listener and the network calls live in GlanceKit's GoogleAccount.
public enum GoogleAuth {
  public static let scopes = ["openid", "email", "https://www.googleapis.com/auth/calendar.events"]
  public static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
  static let authorizeURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
  static let revokeURL = URL(string: "https://oauth2.googleapis.com/revoke")!

  /// 32 random bytes, base64url: a PKCE verifier or a state.
  public static func randomToken() -> String { PKCE.randomToken() }

  /// PKCE's S256 challenge: base64url(SHA-256(verifier)).
  public static func challenge(for verifier: String) -> String { PKCE.challenge(for: verifier) }

  public static func consentURL(clientID: String, redirect: String, state: String, verifier: String) -> URL {
    var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: clientID),
      URLQueryItem(name: "redirect_uri", value: redirect),
      URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "code_challenge", value: challenge(for: verifier)),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "access_type", value: "offline"),
      URLQueryItem(name: "prompt", value: "consent"),
    ]
    return components.url!
  }

  /// What a request on the loopback port means: Google's redirect with a code, the user saying no, or anything else
  /// (a favicon, a stale tab, another state), which the listener answers 404 and keeps waiting.
  public enum Callback: Equatable, Sendable {
    case code(String)
    case denied
    case invalid
  }

  public static func callback(path: String, state: String) -> Callback {
    guard let components = URLComponents(string: path), components.path == "/" else { return .invalid }
    var items: [String: String] = [:]
    for item in components.queryItems ?? [] where items[item.name] == nil { items[item.name] = item.value ?? "" }
    guard items["state"] == state else { return .invalid }
    if items["error"] == "access_denied" { return .denied }
    if let code = items["code"], !code.isEmpty { return .code(code) }
    return .invalid
  }

  public static func exchangeRequest(code: String, verifier: String, redirect: String, clientID: String,
                                     secret: String) -> URLRequest {
    form(tokenURL, [("grant_type", "authorization_code"), ("code", code), ("code_verifier", verifier),
                    ("redirect_uri", redirect), ("client_id", clientID), ("client_secret", secret)])
  }

  public static func refreshRequest(refreshToken: String, clientID: String, secret: String) -> URLRequest {
    form(tokenURL, [("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("client_id", clientID),
                    ("client_secret", secret)])
  }

  public static func revokeRequest(token: String) -> URLRequest {
    form(revokeURL, [("token", token)])
  }

  public struct Tokens: Equatable, Sendable {
    public var accessToken: String
    public var expiresAt: Date
    /// Only from the code exchange (and only with `access_type=offline`).
    public var refreshToken: String?
    /// From the id_token, when there is one.
    public var email: String?

    public init(accessToken: String, expiresAt: Date, refreshToken: String?, email: String?) {
      self.accessToken = accessToken
      self.expiresAt = expiresAt
      self.refreshToken = refreshToken
      self.email = email
    }
  }

  public enum TokenError: Error, Equatable, Sendable {
    /// The refresh token was revoked or expired: signed out.
    case invalidGrant
    case failed(Int)
  }

  public static func tokens(from data: Data, status: Int, now: Date) throws -> Tokens {
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    guard status == 200, let access = json["access_token"] as? String else {
      throw json["error"] as? String == "invalid_grant" ? TokenError.invalidGrant : TokenError.failed(status)
    }
    let seconds = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
    return Tokens(accessToken: access, expiresAt: now.addingTimeInterval(seconds),
                  refreshToken: json["refresh_token"] as? String,
                  email: (json["id_token"] as? String).flatMap(email(fromIDToken:)))
  }

  /// The id_token's `email` claim. The token came straight from Google's token endpoint over TLS, so its signature
  /// isn't checked.
  static func email(fromIDToken token: String) -> String? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    guard let data = Data(base64Encoded: base64),
          let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    return json["email"] as? String
  }

  static func base64URL(_ data: Data) -> String { PKCE.base64URL(data) }

  /// An `application/x-www-form-urlencoded` POST; every byte but RFC 3986's unreserved ones is escaped.
  private static func form(_ url: URL, _ fields: [(String, String)]) -> URLRequest {
    let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    let body = fields.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")" }
      .joined(separator: "&")
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(body.utf8)
    request.timeoutInterval = 15
    return request
  }
}
