import Foundation

/// The Cookie header a browser would send with a request (RFC 6265 §5.4), for the side bars' REST calls (spec
/// 2026-10-09-jira-confluence-design.md, "Sessions and requests"): the tabs' sign-in lives in their WebKit data store,
/// not in URLSession's, so the transport reads the store's cookies and sends the matching ones itself. A domain
/// cookie goes to its domain and every host under it, a host cookie only to its host, a Secure cookie only over
/// https, an expired one nowhere; longer paths come first.
public enum AtlassianCookies {
  public static func header(for url: URL, cookies: [HTTPCookie], now: Date = Date()) -> String? {
    guard let host = url.host?.lowercased() else { return nil }
    let https = url.scheme?.lowercased() == "https"
    let path = url.path.isEmpty ? "/" : url.path
    let sent = cookies.filter { cookie in
      if let expires = cookie.expiresDate, expires <= now { return false }
      if cookie.isSecure && !https { return false }
      return domainMatches(host, cookie.domain.lowercased()) && pathMatches(path, cookie.path)
    }
    guard !sent.isEmpty else { return nil }
    return sent.sorted { $0.path.count > $1.path.count }.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
  }

  static func domainMatches(_ host: String, _ domain: String) -> Bool {
    guard domain.hasPrefix(".") else { return host == domain }
    return host == String(domain.dropFirst()) || host.hasSuffix(domain)
  }

  static func pathMatches(_ path: String, _ cookiePath: String) -> Bool {
    let prefix = cookiePath.isEmpty ? "/" : cookiePath
    return prefix == "/" || path == prefix || path.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/")
  }
}
