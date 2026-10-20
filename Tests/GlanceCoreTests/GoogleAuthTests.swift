import Foundation
import Testing
@testable import GlanceCore

@Test func pkceChallengeMatchesRFC7636() {
  #expect(GoogleAuth.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
}

@Test func randomTokensAreURLSafeAndDifferent() {
  let a = GoogleAuth.randomToken(), b = GoogleAuth.randomToken()
  #expect(a != b)
  #expect(a.count == 43)
  #expect(a.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
}

@Test func theConsentURLAsksForOfflineCalendarAccessWithPKCE() {
  let url = GoogleAuth.consentURL(clientID: "cid", redirect: "http://127.0.0.1:5555", state: "st", verifier: "ver")
  let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
    .queryItems!.map { ($0.name, $0.value ?? "") })
  #expect(url.absoluteString.hasPrefix("https://accounts.google.com/o/oauth2/v2/auth?"))
  #expect(items["response_type"] == "code")
  #expect(items["client_id"] == "cid")
  #expect(items["redirect_uri"] == "http://127.0.0.1:5555")
  #expect(items["scope"] == "openid email https://www.googleapis.com/auth/calendar.events")
  #expect(items["state"] == "st")
  #expect(items["code_challenge"] == GoogleAuth.challenge(for: "ver"))
  #expect(items["code_challenge_method"] == "S256")
  #expect(items["access_type"] == "offline")
  #expect(items["prompt"] == "consent")
}

@Test func theCallbackNeedsTheRightState() {
  #expect(GoogleAuth.callback(path: "/?state=st&code=4/0Ab-x", state: "st") == .code("4/0Ab-x"))
  #expect(GoogleAuth.callback(path: "/?state=other&code=abc", state: "st") == .invalid)
  #expect(GoogleAuth.callback(path: "/?state=st&error=access_denied", state: "st") == .denied)
  #expect(GoogleAuth.callback(path: "/?state=st", state: "st") == .invalid)
  #expect(GoogleAuth.callback(path: "/favicon.ico", state: "st") == .invalid)
  #expect(GoogleAuth.callback(path: "/?error=access_denied", state: "st") == .invalid)
}

@Test func theCodeExchangeIsAFormPost() throws {
  let request = GoogleAuth.exchangeRequest(code: "4/0A b+c", verifier: "ver", redirect: "http://127.0.0.1:5555",
                                           clientID: "cid", secret: "sec")
  #expect(request.httpMethod == "POST")
  #expect(request.url == GoogleAuth.tokenURL)
  #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
  let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
  #expect(body.contains("grant_type=authorization_code"))
  #expect(body.contains("code=4%2F0A%20b%2Bc"))
  #expect(body.contains("code_verifier=ver"))
  #expect(body.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A5555"))
  #expect(body.contains("client_secret=sec"))
}

@Test func theRefreshIsAFormPost() throws {
  let request = GoogleAuth.refreshRequest(refreshToken: "1//rt", clientID: "cid", secret: "sec")
  let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
  #expect(body.contains("grant_type=refresh_token"))
  #expect(body.contains("refresh_token=1%2F%2Frt"))
}

/// An id_token whose payload is `{"email":"me@example.com","sub":"1"}` (unsigned; Glance doesn't check signatures).
private let idToken = "eyJhbGciOiJub25lIn0." + Data(#"{"email":"me@example.com","sub":"1"}"#.utf8)
  .base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-")
  .replacingOccurrences(of: "/", with: "_") + ".sig"

@Test func aTokenResponseGivesTheTokensAndTheEmail() throws {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  let json = #"{"access_token":"ya29.x","expires_in":3599,"refresh_token":"1//rt","id_token":"\#(idToken)"}"#
  let tokens = try GoogleAuth.tokens(from: Data(json.utf8), status: 200, now: now)
  #expect(tokens == GoogleAuth.Tokens(accessToken: "ya29.x", expiresAt: now.addingTimeInterval(3599),
                                      refreshToken: "1//rt", email: "me@example.com"))
}

@Test func aRefreshResponseHasNoRefreshToken() throws {
  let tokens = try GoogleAuth.tokens(from: Data(#"{"access_token":"a","expires_in":10}"#.utf8), status: 200, now: .now)
  #expect(tokens.refreshToken == nil)
  #expect(tokens.email == nil)
}

@Test func invalidGrantMeansSignedOut() {
  #expect(throws: GoogleAuth.TokenError.invalidGrant) {
    try GoogleAuth.tokens(from: Data(#"{"error":"invalid_grant"}"#.utf8), status: 400, now: .now)
  }
  #expect(throws: GoogleAuth.TokenError.failed(500)) {
    try GoogleAuth.tokens(from: Data("oops".utf8), status: 500, now: .now)
  }
}
