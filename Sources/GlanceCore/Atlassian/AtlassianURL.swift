import Foundation

/// Where a navigation in a Jira or Confluence tab goes, and which pages are sign-in pages (spec
/// 2026-10-09-jira-confluence-design.md, "Links and downloads"). The site's own pages of the tab's product stay; its
/// other product's go to that product's tab; Atlassian's sign-in and media hosts stay on Cloud; anything else opens
/// in the default browser, except while signing in, when every web page stays so identity providers work.
public enum AtlassianURL {
  public enum Route: Equatable, Sendable {
    case stay
    case other(AtlassianProduct)
    case browser
  }

  /// Cloud's sign-in, which a session refresh may also pass through.
  static let identityHosts: Set<String> = ["id.atlassian.com", "auth.atlassian.com"]
  /// Where Cloud's attachments come from: they show or download in the tab.
  static let mediaHosts: Set<String> = ["api.media.atlassian.com"]

  public static func route(_ url: URL, from product: AtlassianProduct, site: AtlassianSite,
                           signingIn: Bool) -> Route {
    guard let scheme = url.scheme?.lowercased() else { return .browser }
    if ["about", "blob", "data"].contains(scheme) { return .stay }
    guard scheme == "https" || scheme == "http" else { return .browser }
    let owner = self.product(of: url, site: site)
    if owner == product || signingIn { return .stay }
    if let owner { return .other(owner) }
    let host = url.host?.lowercased() ?? ""
    if site.flavor == .cloud, identityHosts.contains(host) || mediaHosts.contains(host) { return .stay }
    return .browser
  }

  /// Which of `site`'s products an address belongs to; nil for anywhere else. On Cloud the site's host is Jira except
  /// under /wiki; on Data Center it's the product whose base (host, port and path) the address is under, the longer
  /// base winning when both share a host.
  public static func product(of url: URL, site: AtlassianSite) -> AtlassianProduct? {
    guard let host = url.host?.lowercased() else { return nil }
    if site.flavor == .cloud {
      guard let base = site.jiraURL ?? site.confluenceURL, host == base.host?.lowercased() else { return nil }
      return url.path == "/wiki" || url.path.hasPrefix("/wiki/") ? .confluence : .jira
    }
    let matches = AtlassianProduct.allCases.compactMap { product -> (AtlassianProduct, Int)? in
      guard let base = site.url(product), base.host?.lowercased() == host, port(base) == port(url),
            isUnder(url.path, base.path) else { return nil }
      return (product, base.path.count)
    }
    return matches.max { $0.1 < $1.1 }?.0
  }

  /// A page that asks the user to sign in: Cloud's id.atlassian.com and auth.atlassian.com pages (not its profile
  /// pages); Data Center's login pages and SSO servlets on the site.
  public static func isSignIn(_ url: URL, site: AtlassianSite) -> Bool {
    let host = url.host?.lowercased() ?? ""
    if site.flavor == .cloud, identityHosts.contains(host) {
      return !url.path.lowercased().hasPrefix("/manage-profile")
    }
    guard product(of: url, site: site) != nil else { return false }
    let path = url.path.lowercased()
    return ["login.jsp", "login.action", "login"].contains(url.lastPathComponent.lowercased())
      || path.contains("/plugins/servlet/samlsso") || path.contains("/plugins/servlet/external-login")
  }

  static func port(_ url: URL) -> Int? {
    if let port = url.port { return port }
    switch url.scheme?.lowercased() {
    case "https": return 443
    case "http": return 80
    default: return nil
    }
  }

  /// `path` is `prefix` or below it, segment by segment ("/jira/x" is under "/jira", "/jiraX" isn't).
  static func isUnder(_ path: String, _ prefix: String) -> Bool {
    let base = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
    return base.isEmpty || path == base || path.hasPrefix(base + "/")
  }
}
