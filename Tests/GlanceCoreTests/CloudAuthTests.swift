import Foundation
import Testing
@testable import GlanceCore

private let env = CloudEnvironment.local

private func items(_ url: URL) -> [String: String] {
  Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
    .map { ($0.name, $0.value ?? "") })
}

/// A JWT-shaped token whose payload is `payload` (the app never checks signatures; the server does).
func fakeAccessToken(_ payload: String) -> String {
  let body = Data(payload.utf8).base64EncodedString()
    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  return "eyJhbGciOiJFZERTQSJ9.\(body).signature"
}

@Suite struct CloudAuthTests {
  @Test func releaseBuildsUseProductionAndDevelopmentBuildsWhatWasPicked() {
    #expect(CloudEnvironment.current(development: false, saved: "local").name == .production)
    #expect(CloudEnvironment.current(development: true, saved: nil).name == .local)
    #expect(CloudEnvironment.current(development: true, saved: "production").name == .production)
    #expect(CloudEnvironment.current(development: true, saved: "pilot").name == .local)
    #expect(CloudEnvironment.local.isSetUp)
    #expect(!CloudEnvironment.production.isSetUp)
    #expect(CloudEnvironment.local.keychainAccount == "glance-server-local")
    #expect(CloudEnvironment.Name.allCases.map(\.title) == ["Local", "Production"])
    #expect(throws: CloudError.notSetUp) { try CloudAuth.refreshRequest(.production, refreshToken: "r") }
  }

  @Test func theStartURLCarriesTheChallengeAndTheMacsName() throws {
    let url = try CloudAuth.startURL(env, provider: .google, verifier: "v", device: "Ada's Mac")
    #expect(url.path == "/v1/auth/google/start")
    #expect(items(url) == ["code_challenge": PKCE.challenge(for: "v"), "device": "Ada's Mac"])
    let link = try CloudAuth.linkURL(env, provider: .apple, ticket: "t1", verifier: "v")
    #expect(link.path == "/v1/auth/apple/start" && items(link) == ["code_challenge": PKCE.challenge(for: "v"), "link_ticket": "t1"])
  }

  @Test func aPlusInAQueryValueIsEncodedSoTheServerDoesNotReadASpace() throws {
    let url = try CloudAuth.startURL(env, provider: .github, verifier: "v", device: "C++ Mac")
    #expect(url.absoluteString.contains("device=C%2B%2B%20Mac"))
    #expect(items(url)["device"] == "C++ Mac")
  }

  @Test func theSheetsEndingIsReadIntoACallback() {
    #expect(CloudAuth.callback(URL(string: "glance://auth/done?code=abc")!) == .code("abc"))
    #expect(CloudAuth.callback(URL(string: "glance://auth/done?link_code=abc")!) == .linkCode("abc"))
    #expect(CloudAuth.callback(URL(string: "glance://auth/done?error=cancelled")!) == .failed(.cancelled))
    #expect(CloudAuth.callback(URL(string: "glance://auth/done?error=identity_in_use")!)
      == .failed(.rejected(code: "identity_in_use", message: "That sign-in already belongs to another Glance account.")))
    #expect(CloudAuth.callback(URL(string: "glance://auth/done?error=expired")!)
      == .failed(.rejected(code: "expired", message: "Sign-in took too long. Try again.")))
    #expect(CloudAuth.callback(URL(string: "glance://auth/done")!) == .invalid)
    #expect(CloudAuth.callback(URL(string: "glance://other/done?code=abc")!) == .invalid)
    #expect(CloudAuth.callback(URL(string: "https://evil.example/auth/done?code=abc")!) == .invalid)
  }

  @Test func onlyWellFormedInviteLinksGiveAToken() {
    let token = String(repeating: "a", count: 42) + "_"
    #expect(CloudAuth.inviteToken(from: URL(string: "glance://invite/\(token)")!) == token)
    #expect(CloudAuth.inviteToken(from: URL(string: "glance://invite/short")!) == nil)
    #expect(CloudAuth.inviteToken(from: URL(string: "glance://invite/\(token)/extra")!) == nil)
    #expect(CloudAuth.inviteToken(from: URL(string: "glance://auth/\(token)")!) == nil)
    #expect(CloudAuth.inviteToken(from: URL(string: "https://x.example/invite/\(token)")!) == nil)
  }

  @Test func requestsAreJSONWithTheRightMethodAndPath() throws {
    let token = try CloudAuth.tokenRequest(env, code: "c", verifier: "v")
    #expect(token.httpMethod == "POST" && token.url?.absoluteString == "http://localhost:8080/v1/auth/token")
    #expect(try JSONDecoder().decode([String: String].self, from: token.httpBody!) == ["code": "c", "code_verifier": "v"])
    let apple = try CloudAuth.appleRequest(env, identityToken: "id", nonce: "n", name: nil, device: "Mac")
    #expect(try JSONDecoder().decode([String: String].self, from: apple.httpBody!) == ["identity_token": "id", "nonce": "n", "device": "Mac"])
    let all = try CloudAuth.logoutRequest(env, everywhere: true)
    #expect(all.httpMethod == "POST" && all.url?.path == "/v1/auth/logout-all" && all.value(forHTTPHeaderField: "Authorization") == nil)
    let one = try CloudAuth.logoutRequest(env, everywhere: false)
    #expect(one.httpMethod == "POST" && one.url?.path == "/v1/auth/logout" && one.value(forHTTPHeaderField: "Authorization") == nil)
    let complete = try CloudAuth.linkCompleteRequest(env, code: "lc", verifier: "v")
    #expect(complete.httpMethod == "POST" && complete.url?.path == "/v1/auth/link/complete")
    #expect(complete.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(try JSONDecoder().decode([String: String].self, from: complete.httpBody!) == ["code": "lc", "code_verifier": "v"])
    let get = try CloudAuth.request(env, "GET", "/v1/me")
    #expect(get.httpBody == nil && get.value(forHTTPHeaderField: "Content-Type") == nil)
  }

  @Test func theTokenAnswerBecomesASession() throws {
    let json = #"{"access_token":"a1","expires_at":2000000000,"refresh_token":"r1","user":{"id":"u1","name":"Ada","email":"ada@example.com","avatar_url":"https://example.com/a.png"}}"#
    let session = try CloudAuth.session(from: Data(json.utf8), status: 200)
    #expect(session.accessToken == "a1" && session.refreshToken == "r1")
    #expect(session.expiresAt == Date(timeIntervalSince1970: 2_000_000_000))
    #expect(session.user == CloudUser(id: "u1", email: "ada@example.com", name: "Ada", avatarURL: URL(string: "https://example.com/a.png")))
  }

  @Test func errorsKeepTheServersCodeAndMessage() {
    let body = Data(#"{"error":{"code":"session_revoked","message":"You were signed out. Sign in again."}}"#.utf8)
    let error = CloudAuth.error(from: body, status: 401)
    #expect(error == .rejected(code: "session_revoked", message: "You were signed out. Sign in again."))
    #expect(error.endsSession)
    #expect(!CloudAuth.error(from: Data(#"{"error":{"code":"rate_limited","message":"x"}}"#.utf8), status: 429).endsSession)
    #expect(CloudAuth.error(from: Data("<html>".utf8), status: 502) == .failed(502))
    #expect(throws: CloudError.rejected(code: "invalid_code", message: "m")) {
      try CloudAuth.session(from: Data(#"{"error":{"code":"invalid_code","message":"m"}}"#.utf8), status: 401)
    }
  }

  @Test func entitlementsComeFromTheAccessToken() {
    let token = fakeAccessToken(#"{"sub":"u1","ent":{"w1":["cloud_voice","journal_sync"],"w2":[]}}"#)
    #expect(CloudAuth.entitlements(accessToken: token) == ["w1": ["cloud_voice", "journal_sync"], "w2": []])
    #expect(CloudAuth.entitlements(accessToken: fakeAccessToken(#"{"sub":"u1"}"#)) == [:])
    #expect(CloudAuth.entitlements(accessToken: "garbage") == [:])
    #expect(CloudAuth.entitlements(accessToken: "a.%%%.c") == [:])
  }

  @Test func messagesNameTheGlanceServer() {
    #expect(CloudError.unreachable.message(in: .local).contains("docker compose"))
    #expect(CloudError.unreachable.message(in: .production) == "Can't reach the Glance server. Check your connection.")
    #expect(CloudError.notSetUp.message(in: .production) == "The Glance server isn't set up in this build.")
  }
}
