import Foundation

/// The address space of an automation's web UI (spec 2026-10-09-automations-design.md, "Web UI contract"):
/// `glance-automation://<id>/<path>` is a file of that package, `glance-automation://glance/<asset>` one of Glance's
/// shared assets (tokens.css, glance.js and the two fonts). Pure: Studio's scheme handler reads the files.
public enum AutomationWeb {
  public static let scheme = "glance-automation"
  /// The shared assets' host. An automation whose id is `glance` still serves its own files, except these names.
  public static let assetsHost = "glance"
  public static let assets: Set<String> = ["tokens.css", "glance.js", "fonts/dm-sans.woff2",
                                           "fonts/jetbrains-mono.woff2"]
  /// The page the automation tab opens.
  public static let indexPath = "ui/index.html"
  /// The spec's policy, word for word: nothing loads from outside the scheme, so the page has no network.
  public static let contentSecurityPolicy = "default-src glance-automation:; style-src glance-automation: "
    + "'unsafe-inline'; script-src glance-automation: 'unsafe-inline'; form-action 'none'; base-uri 'none'; "
    + "object-src 'none'"
  /// The policy as the first element of a page's `<head>` (the response header carries it too).
  public static let policyMeta = #"<meta http-equiv="Content-Security-Policy" content=""# + contentSecurityPolicy
    + #"">"#
  /// The schemes the rule list blocks, one rule each: WebKit's rule compiler has no `|` in a url-filter.
  public static let blockedSchemes = ["https?", "wss?", "ftp", "file"]
  /// A WebKit content rule list, the policy's second lock: web, socket, FTP and file loads are blocked.
  public static let blockRules = "[" + blockedSchemes.map {
    #"{"trigger":{"url-filter":"^\#($0):"},"action":{"type":"block"}}"#
  }.joined(separator: ",") + "]"

  public enum Route: Equatable, Sendable {
    /// One of `assets`.
    case asset(String)
    /// A file of the package `id`, by its path inside the package folder.
    case package(id: String, path: String)
    /// Not served; why, for the log.
    case refused(String)
  }

  /// The automation tab's page: `glance-automation://<id>/ui/index.html`. `id` is an automation id (`isID`).
  public static func pageURL(_ id: String) -> URL {
    URL(string: "\(scheme)://\(id)/\(indexPath)") ?? URL(fileURLWithPath: "/")
  }

  /// What a request asks for. The host is the automation (WebKit may lowercase it, so it's compared lowercased); the
  /// path is percent-decoded once and must stay inside the package; an empty path is the index page.
  public static func route(_ url: URL) -> Route {
    guard url.scheme?.lowercased() == scheme else { return .refused("not a \(scheme): address") }
    guard let host = url.host?.lowercased(), isID(host), !AutomationLibraryLayout.reservedIDs.contains(host) else {
      return .refused("no automation in that address")
    }
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let path = safePath(components.percentEncodedPath) else {
      return .refused("the path leaves the package or names a hidden file")
    }
    if host == assetsHost, assets.contains(path) { return .asset(path) }
    return .package(id: host, path: path.isEmpty ? indexPath : path)
  }

  /// An automation id: 1 to 48 of a-z, 0-9 and "-".
  public static func isID(_ text: String) -> Bool {
    (1...48).contains(text.count)
      && text.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
  }

  /// The path inside the package, without empty segments; nil when it could leave the package or names something
  /// hidden: a segment starting with "." (so "..", "." and ".git"), a backslash, a NUL, or text that doesn't decode.
  /// Decoding first means "%2e%2e" and "..%2F" are caught like "..".
  public static func safePath(_ percentEncoded: String) -> String? {
    guard let decoded = percentEncoded.removingPercentEncoding,
          !decoded.contains("\\"), !decoded.contains("\u{0}") else { return nil }
    let segments = decoded.split(separator: "/", omittingEmptySubsequences: true)
    guard segments.allSatisfy({ !$0.hasPrefix(".") }) else { return nil }
    return segments.joined(separator: "/")
  }

  /// `path` is strictly inside `root`; both have their symlinks resolved already, which is what keeps a symlink in a
  /// package from serving a file somewhere else.
  public static func isInside(_ path: String, root: String) -> Bool {
    let prefix = root.hasSuffix("/") ? root : root + "/"
    return path.hasPrefix(prefix) && path.count > prefix.count
  }

  public static func isHTML(_ path: String) -> Bool {
    ["html", "htm"].contains((path as NSString).pathExtension.lowercased())
  }

  /// The response headers: the type (text in UTF-8), the length, no caching (a save shows at once), no sniffing,
  /// and the CSP.
  public static func headers(path: String, length: Int) -> [String: String] {
    var type = PreviewFiles.mimeType(forPath: path)
    if type.hasPrefix("text/") || ["application/json", "application/xml", "image/svg+xml"].contains(type) {
      type += "; charset=utf-8"
    }
    var headers = ["Content-Type": type, "Content-Length": String(length), "Cache-Control": "no-store",
                   "X-Content-Type-Options": "nosniff"]
    // On every response, not only .html: an SVG or XML document can run script too.
    headers["Content-Security-Policy"] = contentSecurityPolicy
    return headers
  }

  /// The page with `policyMeta` as the first thing in its `<head>` (or after `<html>`, or after the doctype, or at
  /// the very start), so the policy applies before any of the page's own elements.
  public static func injectingPolicy(_ html: String) -> String {
    for pattern in [#"<head(\s[^>]*)?>"#, #"<html(\s[^>]*)?>"#, #"<!doctype[^>]*>"#] {
      guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
            let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
            let range = Range(match.range, in: html) else { continue }
      return String(html[..<range.upperBound]) + policyMeta + String(html[range.upperBound...])
    }
    return policyMeta + html
  }

  /// glance-automation://glance/tokens.css: the two fonts, the design system's tokens.css as it is (light and dark
  /// by `prefers-color-scheme`), and a base that gives a page the house look with no CSS of its own. The body stays
  /// transparent: the tab's own background shows through.
  public static func tokensCSS(designTokens: String) -> String {
    """
    /* Glance tokens for automation UIs: design-system/glance/tokens.css, its fonts, and a base. */
    @font-face { font-family: "DM Sans"; font-weight: 400 700; src: url(fonts/dm-sans.woff2) format("woff2"); }
    @font-face { font-family: "JetBrains Mono"; font-weight: 400 600;
      src: url(fonts/jetbrains-mono.woff2) format("woff2"); }

    \(designTokens)

    /* Base */
    html { background: transparent; }
    body { margin: 0; font: var(--fs-body)/var(--lh-body) var(--sans); color: var(--ink); background: transparent;
      -webkit-font-smoothing: antialiased; }
    code, kbd, pre, samp { font-family: var(--mono); }
    a { color: var(--coral-ink); }
    ::selection { background: var(--sel); }
    """
  }
}
