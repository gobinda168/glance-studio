import Foundation

/// A meeting's call link, found in a calendar event (spec 2026-10-08-meeting-nudges-design.md, "MeetingLink"): Google
/// Meet, Zoom, Teams or Webex, from the event's URL field, then its location, then its notes.
public struct MeetingLink: Equatable, Sendable, Codable {
  public enum Provider: String, Sendable, Codable {
    case meet, zoom, teams, webex

    public var name: String {
      switch self {
      case .meet: "Google Meet"
      case .zoom: "Zoom"
      case .teams: "Microsoft Teams"
      case .webex: "Webex"
      }
    }
  }

  public let provider: Provider
  public let url: URL

  public init(provider: Provider, url: URL) {
    self.provider = provider
    self.url = url
  }

  /// The first call link in the URL field, else the location, else the notes.
  public static func find(url: String?, location: String?, notes: String?) -> MeetingLink? {
    for text in [url, location, notes].compactMap({ $0 }) where !text.isEmpty {
      if let link = first(in: text) { return link }
    }
    return nil
  }

  /// The link for the call's own app (Zoom, Teams), used when that app is installed; nil for the others.
  public var appURL: URL? {
    switch provider {
    case .zoom:
      let parts = url.path.split(separator: "/")
      guard parts.count >= 2, parts[0] == "j", let host = url.host else { return nil }
      var components = URLComponents()
      components.scheme = "zoommtg"
      components.host = host
      components.path = "/join"
      var items = [URLQueryItem(name: "action", value: "join"), URLQueryItem(name: "confno", value: String(parts[1]))]
      if let pwd = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "pwd" })?
        .value {
        items.append(URLQueryItem(name: "pwd", value: pwd))
      }
      components.queryItems = items
      return components.url
    case .teams:
      let text = url.absoluteString
      guard url.host == "teams.microsoft.com", url.path.hasPrefix("/l/meetup-join/"), let host = text.range(of: "teams.microsoft.com") else { return nil }
      return URL(string: "msteams:" + text[host.upperBound...])
    case .meet, .webex:
      return nil
    }
  }

  /// The page to show inside Glance: Zoom's browser client for an invite link (the invite page itself only asks to
  /// open the Zoom app); every other link as it is.
  public var webURL: URL {
    guard provider == .zoom, let host = url.host else { return url }
    let parts = url.path.split(separator: "/")
    guard parts.count >= 2, parts[0] == "j" else { return url }
    var components = URLComponents()
    components.scheme = "https"
    components.host = host
    components.path = "/wc/\(parts[1])/join"
    components.queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
      .filter { $0.name == "pwd" }
    return components.url ?? url
  }

  private static func first(in text: String) -> MeetingLink? {
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
    for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
      guard let found = match.url else { continue }
      let url = trimmed(unwrapped(found))
      if let provider = provider(of: url) { return MeetingLink(provider: provider, url: url) }
    }
    return nil
  }

  /// Google Calendar's redirect (`https://www.google.com/url?q=<link>`) around the real link.
  private static func unwrapped(_ url: URL) -> URL {
    guard let host = url.host?.lowercased(), host == "google.com" || host == "www.google.com", url.path == "/url",
          let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "q" || $0.name == "url" })?.value,
          let inner = URL(string: target)
    else { return url }
    return inner
  }

  /// Punctuation the detector kept at the end of a link written in a sentence.
  private static func trimmed(_ url: URL) -> URL {
    var text = url.absoluteString
    while let last = text.last, ".,;:)]>'\"".contains(last) { text.removeLast() }
    return URL(string: text) ?? url
  }

  private static func provider(of url: URL) -> Provider? {
    guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
          let host = url.host?.lowercased() else { return nil }
    let path = url.path
    if host == "meet.google.com", path.count > 1 { return .meet }
    let zoom = host == "zoom.us" || host.hasSuffix(".zoom.us") || host == "zoomgov.com" || host.hasSuffix(".zoomgov.com")
    if zoom, ["/j/", "/my/", "/w/", "/s/", "/wc/join/"].contains(where: { path.hasPrefix($0) }) { return .zoom }
    if host == "teams.microsoft.com", path.hasPrefix("/l/meetup-join/") || path.hasPrefix("/meet/") { return .teams }
    if host == "teams.live.com", path.hasPrefix("/meet/") { return .teams }
    if host.hasSuffix(".webex.com"), path.count > 1 { return .webex }
    return nil
  }
}
