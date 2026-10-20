import Foundation

/// The search engine the Browser's address field searches with (Settings → Browser); DuckDuckGo unless chosen.
public enum SearchEngine: String, CaseIterable, Codable, Sendable {
  case duckDuckGo, google, bing, kagi

  public init(saved: String?) {
    self = saved.flatMap(SearchEngine.init(rawValue:)) ?? .duckDuckGo
  }

  public var title: String {
    switch self {
    case .duckDuckGo: "DuckDuckGo"
    case .google: "Google"
    case .bing: "Bing"
    case .kagi: "Kagi"
    }
  }

  public func url(for query: String) -> URL {
    let base = switch self {
    case .duckDuckGo: "https://duckduckgo.com/"
    case .google: "https://www.google.com/search"
    case .bing: "https://www.bing.com/search"
    case .kagi: "https://kagi.com/search"
    }
    var components = URLComponents(string: base)!
    components.percentEncodedQuery = "q=" + Self.encode(query)
    return components.url!
  }

  /// Query encoding that also escapes `&`, `+`, `=` and `?`, which `URLQueryItem` leaves alone.
  private static func encode(_ text: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&+=?#")
    return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
  }
}

/// What the Browser does with an address (spec 2026-10-10-browser-design.md, "Surface").
public enum BrowserURL {
  /// Where an address opens: in a Browser tab, or handed to macOS (mail, calls, Slack's and Zoom's apps, files).
  public enum Destination: Equatable, Sendable { case tab, system }

  /// Schemes a typed address may start with besides http and https.
  static let typedSchemes: Set<String> = ["about", "mailto", "tel"]
  static let tabSchemes: Set<String> = ["http", "https", "about", "data", "blob"]

  /// What the address field opens for `text`: an address as typed; `localhost`, `:3000` and IP forms on http; a
  /// dotted name on https; anything else a search with `engine`. nil for blank text.
  public static func resolve(_ text: String, engine: SearchEngine) -> URL? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return address(trimmed) ?? engine.url(for: trimmed)
  }

  /// Whether `resolve` reads `text` as an address rather than a search.
  public static func isAddress(_ text: String) -> Bool {
    address(text.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
  }

  static func address(_ text: String) -> URL? {
    guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
    let lower = text.lowercased()
    if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
      guard let url = URL(string: text), let host = url.host, !host.isEmpty else { return nil }
      return url
    }
    if let colon = lower.firstIndex(of: ":"), typedSchemes.contains(String(lower[..<colon])) {
      return URL(string: text)
    }
    if lower.hasPrefix(":") {
      guard let url = URL(string: "http://localhost" + text), url.port != nil else { return nil }
      return url
    }
    let host = hostPart(lower)
    if isLocalHost(host) { return URL(string: "http://" + text) }
    if looksLikeDomain(host), let url = URL(string: "https://" + text), url.host != nil { return url }
    return nil
  }

  /// The host of a typed address without a scheme: up to the first "/", "?" or "#", without a port; IPv6 keeps
  /// its brackets.
  private static func hostPart(_ text: String) -> String {
    let end = text.firstIndex { "/?#".contains($0) } ?? text.endIndex
    let authority = String(text[..<end])
    if authority.hasPrefix("[") {
      return authority.firstIndex(of: "]").map { String(authority[...$0]) } ?? authority
    }
    return authority.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
      ?? authority
  }

  /// localhost, *.localhost, [::1], or a dotted IPv4 address.
  private static func isLocalHost(_ host: String) -> Bool {
    if host == "localhost" || host.hasSuffix(".localhost") || host == "[::1]" { return true }
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    return parts.count == 4 && parts.allSatisfy { part in Int(part).map { (0...255).contains($0) } ?? false }
  }

  /// A dotted name whose last label is two or more letters ("github.com", "docs.rs"); not "1.5" or "file.".
  private static func looksLikeDomain(_ host: String) -> Bool {
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }), let last = labels.last else { return false }
    return last.count >= 2 && last.allSatisfy(\.isLetter)
  }

  public static func destination(_ url: URL) -> Destination {
    tabSchemes.contains(url.scheme?.lowercased() ?? "") ? .tab : .system
  }

  /// The address field at rest: the host without "www.", with its port ("github.com", "localhost:3000",
  /// "[::1]:3000"); the whole address when there's no host ("about:blank").
  public static func displayHost(_ url: URL) -> String {
    guard let raw = url.host, !raw.isEmpty else { return url.absoluteString }
    var host = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if host.contains(":") { host = "[\(host)]" }
    if host.hasPrefix("www.") { host.removeFirst(4) }
    return url.port.map { "\(host):\($0)" } ?? host
  }

  /// This Mac: localhost, *.localhost, 127.0.0.1, ::1.
  public static func isLocal(_ url: URL) -> Bool {
    guard let raw = url.host?.lowercased() else { return false }
    let host = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    return host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "::1"
  }

  /// The name a site's icon is cached under: its host (":" as "_"), plus "-wiki" under /wiki, so Jira and
  /// Confluence on one Cloud site keep their own icons. nil without a host.
  public static func iconKey(_ url: URL) -> String? {
    guard let raw = url.host?.lowercased(), !raw.isEmpty else { return nil }
    let host = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).replacingOccurrences(of: ":", with: "_")
    return url.path.lowercased().hasPrefix("/wiki") ? host + "-wiki" : host
  }
}
