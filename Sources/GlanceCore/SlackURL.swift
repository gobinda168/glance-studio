import Foundation

/// Where a navigation in a Slack view goes (spec 2026-10-09-chats-slack-design.md, "Links and downloads"): Slack's own
/// pages stay, file downloads download, anything else opens in the default browser, except that while signing in
/// (a sign-in tab, a pop-up, a signed-out workspace) every web page stays, so identity providers work.
public enum SlackURL {
  public enum Route: Equatable, Sendable { case stay, download, browser }

  public static let signInURL = URL(string: "https://slack.com/signin")!

  public static func route(_ url: URL, signingIn: Bool) -> Route {
    if url.scheme == "about" { return .stay }
    guard url.scheme == "https" || url.scheme == "http" else { return .browser }
    if url.host == "files.slack.com", url.path.contains("/download/") { return .download }
    if isSlackHost(url.host) || signingIn { return .stay }
    return .browser
  }

  public enum NewWindow: Equatable, Sendable { case sameView, popUp, browser }

  /// Where a window a Slack page opens goes: a Slack page loads in the same view (the workspace picker opens the
  /// chosen workspace in a new window), a blank window or, while signing in, an identity provider gets a pop-up, and
  /// anything else opens in the default browser.
  public static func newWindow(_ url: URL, signingIn: Bool) -> NewWindow {
    if url.scheme == "about" || url.absoluteString.isEmpty { return .popUp }
    switch route(url, signingIn: signingIn) {
    case .browser: return .browser
    case .download: return .sameView
    case .stay: return isSlackHost(url.host) ? .sameView : .popUp
    }
  }

  /// The team id in a client address (`app.slack.com/client/<team>[/…]`).
  public static func teamID(_ url: URL) -> String? {
    guard url.host == "app.slack.com" else { return nil }
    let parts = url.pathComponents.filter { $0 != "/" }
    guard parts.count >= 2, parts[0] == "client" else { return nil }
    let team = parts[1]
    guard team.first == "T" || team.first == "E" else { return nil }
    return team
  }

  /// A page that asks the user to sign in: Slack's sign-in, its password and SSO pages, and "get started".
  public static func isSignIn(_ url: URL) -> Bool {
    guard isSlackHost(url.host) else { return false }
    let path = url.path.lowercased()
    return path.hasPrefix("/signin") || path.hasPrefix("/sign_in") || path.hasPrefix("/get-started")
      || path.hasPrefix("/sso") || path.hasPrefix("/workspace-signin")
  }

  public static func isSlackHost(_ host: String?) -> Bool {
    guard let host = host?.lowercased() else { return false }
    return ["slack.com", "slack-edge.com"].contains { host == $0 || host.hasSuffix("." + $0) }
  }
}
