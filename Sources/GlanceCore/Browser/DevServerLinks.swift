import Foundation

/// Dev servers in the Browser: an address on this Mac that a Studio terminal opens (a ⌘-clicked link, a dev server
/// opening its page through `BROWSER`) shows in a Browser tab instead of the default browser, until Settings → Browser
/// turns it off.
public enum DevServerLinks {
  /// The setting's key in Glance's defaults; on until switched off.
  public static let settingKey = "browserOpensDevServers"

  public static func isEnabled(in defaults: UserDefaults) -> Bool {
    defaults.object(forKey: settingKey) as? Bool ?? true
  }

  /// `text` as a dev server's page when it is one: http or https on localhost, *.localhost, 127.x.x.x, [::1] or
  /// 0.0.0.0, any port. A server listening on every address (0.0.0.0, [::]) is shown on localhost, which WebKit
  /// loads; nil for anything else.
  public static func devServerURL(_ text: String) -> URL? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
          let raw = url.host?.lowercased(), !raw.isEmpty else { return nil }
    let host = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if host == "0.0.0.0" || host == "::" {
      guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
      components.host = "localhost"
      return components.url
    }
    return isLoopback(host) ? url : nil
  }

  /// localhost, *.localhost, 127.x.x.x or ::1 (without brackets).
  static func isLoopback(_ host: String) -> Bool {
    if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" { return true }
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    return parts.count == 4 && parts.first == "127"
      && parts.allSatisfy { part in Int(part).map { (0...255).contains($0) } ?? false }
  }

  /// The same server: scheme, host and port (80 and 443 when not written).
  public static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
    origin(a) != nil && origin(a) == origin(b)
  }

  private static func origin(_ url: URL) -> String? {
    guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
    let port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : -1)
    return "\(scheme)://\(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))):\(port)"
  }

  /// A tab already on the server, asked to open `url`: reload the page it is on when `url` is that page or the
  /// server's front page (a restarted dev server opening "/" keeps the tab where it was), else go to `url`.
  public static func reloads(_ current: URL, for url: URL) -> Bool {
    if current.absoluteString == url.absoluteString { return true }
    return (url.path.isEmpty || url.path == "/") && url.query == nil && url.fragment == nil
  }

  // MARK: The BROWSER helper

  /// The helper's file name: Node dev servers (Vite, Create React App, Storybook, Docusaurus…) run a `BROWSER` ending
  /// in ".js" with node, where any other name would go to `open -a` and fail.
  public static let helperName = "browser.js"

  /// Studio's `BROWSER` for its terminals: a file that is both a shell script and JavaScript. Run as a command
  /// (Python's webbrowser, gh, git) it is sh; run by node it starts sh on itself. sh hands the address to Studio over
  /// the shell bridge (`browse`), and opens it with macOS when Studio doesn't answer `browsed yes`.
  public static let helperScript = #"""
    #!/bin/sh
    ":" /*
    # Glance Studio's BROWSER (DevServerLinks): Studio shows a dev server's page in a Browser tab and anything else in
    # the default browser. The address is the last argument. GLANCE_BROWSER_FALLBACK stands in for open in tests.
    for url in "$@"; do :; done
    if [ -n "${url:-}" ] && [ -S "${GLANCE_SHELL_SOCKET:-}" ]; then
      reply=$(printf 'browse\t%s\t%s\n' "${GLANCE_SHELL_TAB:-}" "$url" | /usr/bin/nc -U -w 3 "$GLANCE_SHELL_SOCKET" 2>/dev/null)
      case $reply in browsed*yes*) exit 0 ;; esac
    fi
    exec "${GLANCE_BROWSER_FALLBACK:-/usr/bin/open}" "$url"
    */
    const { spawnSync } = require("child_process");
    const result = spawnSync("/bin/sh", [__filename, ...process.argv.slice(2)], { stdio: "inherit" });
    process.exit(result.status === null ? 1 : result.status);

    """#
}
