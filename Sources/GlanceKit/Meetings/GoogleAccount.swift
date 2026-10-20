import AppKit
import GlanceCore
import Observation

/// The Google account Decline uses (spec 2026-10-09-meeting-decline-rsvp-design.md, "GoogleAccount"):
/// - Signs in through the default browser with a one-off listener on 127.0.0.1.
/// - Keeps the refresh token and email in the Keychain, and the access token in memory.
/// - Refreshes the access token when it's about to expire, and signs out on `invalid_grant`.
@MainActor @Observable
public final class GoogleAccount {
  public static let shared = GoogleAccount()

  public enum State: Equatable {
    case notSetUp
    case signedOut
    case signingIn
    case signedIn(String)
  }

  public enum SignInError: Error {
    case cancelled
    case timedOut
    case denied
    case failed
  }

  public private(set) var state: State
  @ObservationIgnored private let store = KeychainStore(service: "dev.glance.Glance", account: "google")
  @ObservationIgnored private var access: (token: String, expires: Date)?
  @ObservationIgnored private var signing: Task<String, Error>?
  @ObservationIgnored private var redirect: LoopbackRedirect?

  private struct Saved: Codable {
    var refreshToken: String
    var email: String
  }

  private init() {
    state = .notSetUp
    state = GoogleClient.isSetUp ? (saved.map { .signedIn($0.email) } ?? .signedOut) : .notSetUp
  }

  private var saved: Saved? {
    store.read().flatMap { try? JSONDecoder().decode(Saved.self, from: Data($0.utf8)) }
  }

  public var email: String? {
    if case .signedIn(let email) = state { return email }
    return nil
  }

  /// Signs in, or joins the sign-in already under way. Returns the account's email.
  public func signIn() async throws -> String {
    if let signing { return try await signing.value }
    let task = Task { try await self.runSignIn() }
    signing = task
    defer { signing = nil }
    return try await task.value
  }

  public func cancelSignIn() {
    redirect?.cancel()
  }

  /// Forgets the account here and tells Google to forget the grant (best effort).
  public func signOut() {
    if let refresh = saved?.refreshToken {
      let request = GoogleAuth.revokeRequest(token: refresh)
      Task.detached { _ = try? await URLSession.shared.data(for: request) }
    }
    store.delete()
    access = nil
    state = GoogleClient.isSetUp ? .signedOut : .notSetUp
  }

  /// For `GoogleRSVP.decline`: the access token, refreshed when it has under a minute left or when asked.
  public nonisolated var token: GoogleRSVP.Token {
    { refresh in try await self.accessToken(refresh: refresh) }
  }

  private func accessToken(refresh: Bool) async throws -> String {
    if !refresh, let access, access.expires.timeIntervalSinceNow > 60 { return access.token }
    guard let saved else { throw GoogleRSVP.Failure.signInExpired }
    let request = GoogleAuth.refreshRequest(refreshToken: saved.refreshToken, clientID: GoogleClient.id,
                                            secret: GoogleClient.secret)
    let (data, status) = try await Self.send(request)
    do {
      let tokens = try GoogleAuth.tokens(from: data, status: status, now: Date())
      access = (tokens.accessToken, tokens.expiresAt)
      return tokens.accessToken
    } catch GoogleAuth.TokenError.invalidGrant {
      store.delete()
      access = nil
      state = .signedOut
      throw GoogleRSVP.Failure.signInExpired
    } catch {
      throw GoogleRSVP.Failure.refused(status)
    }
  }

  private func runSignIn() async throws -> String {
    guard GoogleClient.isSetUp else { throw SignInError.failed }
    let previous = state
    state = .signingIn
    let redirect = LoopbackRedirect()
    self.redirect = redirect
    defer { if self.redirect === redirect { self.redirect = nil } }
    do {
      let verifier = GoogleAuth.randomToken()
      let stateToken = GoogleAuth.randomToken()
      let port = try await redirect.start { path in
        switch GoogleAuth.callback(path: path, state: stateToken) {
        case .code(let code): .code(code)
        case .denied: .failed("Sign-in was cancelled")
        case .invalid: .ignore
        }
      }
      let redirectURI = "http://127.0.0.1:\(port)"
      NSWorkspace.shared.open(GoogleAuth.consentURL(clientID: GoogleClient.id, redirect: redirectURI, state: stateToken,
                                                    verifier: verifier))
      let code: String
      do {
        code = try await redirect.code(within: .seconds(180))
      } catch LoopbackRedirect.Failure.cancelled {
        throw SignInError.cancelled
      } catch LoopbackRedirect.Failure.timedOut {
        throw SignInError.timedOut
      } catch LoopbackRedirect.Failure.failed {
        throw SignInError.denied
      }
      let (data, status) = try await Self.send(GoogleAuth.exchangeRequest(
        code: code, verifier: verifier, redirect: redirectURI, clientID: GoogleClient.id, secret: GoogleClient.secret))
      let tokens = try GoogleAuth.tokens(from: data, status: status, now: Date())
      guard let refresh = tokens.refreshToken else { throw SignInError.failed }
      let email = tokens.email ?? "your Google account"
      let json = try JSONEncoder().encode(Saved(refreshToken: refresh, email: email))
      store.save(String(decoding: json, as: UTF8.self))
      access = (tokens.accessToken, tokens.expiresAt)
      state = .signedIn(email)
      return email
    } catch {
      redirect.cancel()
      state = previous == .signingIn ? .signedOut : previous
      throw error
    }
  }

  private nonisolated static func send(_ request: URLRequest) async throws -> (Data, Int) {
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    } catch is URLError {
      throw GoogleRSVP.Failure.offline
    }
  }
}
