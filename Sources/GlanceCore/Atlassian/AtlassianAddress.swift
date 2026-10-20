import Foundation

/// What someone typed into Add a site (spec 2026-10-09-jira-confluence-design.md, "Sites"), as a site's base address:
/// a bare name is a Cloud site, a Cloud link is its site, and a Data Center link keeps its context path (the part
/// before Jira's or Confluence's own pages begin).
public enum AtlassianAddress {
  /// Path segments that begin Jira's or Confluence's own pages: what comes before the first of them is a Data Center
  /// site's context path ("/jira" in https://acme.com/jira/browse/GL-1). A segment with a dot (Dashboard.jspa) ends
  /// it too.
  static let pageSegments: Set<String> = [
    "browse", "secure", "projects", "issues", "plugins", "rest", "servicedesk", "display", "pages", "spaces",
    "x", "label", "labels", "download", "admin", "s", "images", "people", "users",
  ]

  public static func base(_ typed: String) -> URL? {
    var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !text.contains(where: \.isWhitespace), !text.contains("@") else { return nil }
    if !text.contains(".") && !text.contains("/") && !text.contains(":") {
      guard text.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }) else { return nil }
      return URL(string: "https://\(text.lowercased()).atlassian.net")
    }
    let lower = text.lowercased()
    if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
      guard !lower.contains("://") else { return nil }
      text = "https://" + text
    }
    guard let parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(),
          scheme == "http" || scheme == "https", let host = parts.host?.lowercased(), host.contains(".")
    else { return nil }
    var base = URLComponents()
    base.scheme = scheme
    base.host = host
    base.port = parts.port
    if !isCloud(host: host) {
      let context = parts.path.split(separator: "/").map(String.init)
        .prefix { !pageSegments.contains($0.lowercased()) && !$0.contains(".") }
      if !context.isEmpty { base.path = "/" + context.joined(separator: "/") }
    }
    return base.url
  }

  public static func isCloud(_ url: URL) -> Bool {
    url.host.map { isCloud(host: $0.lowercased()) } ?? false
  }

  static func isCloud(host: String) -> Bool { host.hasSuffix(".atlassian.net") }
}
