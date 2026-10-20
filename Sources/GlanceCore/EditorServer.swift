import CryptoKit
import Foundation

/// The VSCodium server behind Glance Studio's editor tab (spec 2026-10-06-vscode-editor-tab-design.md): the pinned
/// release, where it is installed, how it is started, and the page an editor tab loads.
public enum EditorServer {
  public static let version = "1.135.06055"
  /// The ports the server may use. Settings live in the web view's storage for the origin, port included, so the app
  /// keeps one port for good (see `choosePort`).
  public static let ports = 47900...47999

  public struct Release: Equatable, Sendable {
    public let url: URL
    public let sha256: String
    public let size: Int64
  }

  /// The release for a CPU architecture as `uname -m` names it; nil for any other.
  public static func release(arch: String) -> Release? {
    let pinned: [String: (name: String, sha256: String, size: Int64)] = [
      "arm64": ("arm64", "87ffebc1df7bde31b9e863d38fa6121cdebe3e5f9794d65f95f062f986dcfa73", 130_799_447),
      "x86_64": ("x64", "b0038f4ae482d6454bb293ae5b04d4af0834f8c7094f95dfeec3c6519d9fcb74", 132_270_729),
    ]
    guard let entry = pinned[arch] else { return nil }
    let file = "vscodium-reh-web-darwin-\(entry.name)-\(version).tar.gz"
    let url = URL(string: "https://github.com/VSCodium/vscodium/releases/download/\(version)/\(file)")!
    return Release(url: url, sha256: entry.sha256, size: entry.size)
  }

  public struct Paths: Equatable, Sendable {
    /// `~/Library/Application Support/Glance Studio`.
    public let appSupport: URL
    public init(appSupport: URL) { self.appSupport = appSupport }

    public var base: URL { appSupport.appendingPathComponent("editor-server") }
    public var install: URL { base.appendingPathComponent(EditorServer.version) }
    /// Unpacked here first, renamed to `install` only when complete.
    public var staging: URL { base.appendingPathComponent(EditorServer.version + ".partial") }
    public var executable: URL { install.appendingPathComponent("bin/codium-server") }
    public var product: URL { install.appendingPathComponent("product.json") }
    public var data: URL { base.appendingPathComponent("data") }
    public var extensions: URL { data.appendingPathComponent("extensions") }
    public var logs: URL { data.appendingPathComponent("logs") }
    public var token: URL { base.appendingPathComponent("token") }
    public var pidFile: URL { base.appendingPathComponent("server.pid") }
    public var bridgeSocket: URL { appSupport.appendingPathComponent("editor-bridge.sock") }
  }

  private static func dataArguments(_ paths: Paths) -> [String] {
    ["--server-data-dir", paths.data.appendingPathComponent("server").path,
     "--user-data-dir", paths.data.appendingPathComponent("user").path,
     "--extensions-dir", paths.extensions.path]
  }

  /// `codium-server`'s arguments: loopback only, a token file, data in Glance's folders.
  public static func arguments(paths: Paths, port: Int) -> [String] {
    ["--host", "127.0.0.1", "--port", String(port),
     "--connection-token-file", paths.token.path,
     "--accept-server-license-terms"]
      + dataArguments(paths)
      + ["--reconnection-grace-time", "30", "--telemetry-level", "off"]
  }

  /// Installs (or replaces) an extension in the folders the running server uses.
  public static func installExtensionArguments(paths: Paths, vsix: URL) -> [String] {
    ["--install-extension", vsix.path, "--force"] + dataArguments(paths)
  }

  /// The page an editor tab loads for a project. Query values are fully percent-encoded, so a folder with `&`, `#`,
  /// spaces or non-ASCII characters arrives intact.
  public static func workbenchURL(port: Int, token: String, root: String) -> URL {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&=+#?")
    func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value }
    var components = URLComponents()
    components.scheme = "http"
    components.host = "127.0.0.1"
    components.port = port
    components.path = "/"
    components.percentEncodedQuery = "tkn=\(encode(token))&folder=\(encode(root))"
    return components.url!
  }

  /// Whether a navigation stays in the editor tab: the server's own pages (and blob/data/about pages they make).
  /// Everything else opens in the default browser.
  public static func isWorkbench(_ url: URL, port: Int?) -> Bool {
    if ["about", "blob", "data"].contains(url.scheme ?? "") { return true }
    guard let port else { return false }
    return url.scheme == "http" && url.host == "127.0.0.1" && url.port == port
  }

  /// The installed `product.json`, renamed to GS Code (the editor tab's name for it) and with telemetry off. `applicationName` stays: the
  /// server uses it for its own CLI and data folder names.
  public static func patchedProduct(_ product: [String: Any]) -> [String: Any] {
    var patched = product
    patched["nameShort"] = "GS Code"
    patched["nameLong"] = "GS Code"
    patched["enableTelemetry"] = false
    return patched
  }

  /// Bumped when `patchedWorkbench` or `brandedMessages` change, so installs patched by an older app get patched again.
  public static let pagePatchRevision = "3"
  /// The web workbench's own files that carry the product name. The server only sends the browser a few product
  /// fields, so the names in `product.json` never reach the page.
  public static let workbenchFile = "out/vs/code/browser/workbench/workbench.js"
  public static let messageFiles = ["out/nls.messages.js", "out/nls.messages.json"]

  /// The workbench page with its built-in product (the Welcome page's title, About, window titles) renamed, and
  /// without New Window in the File menu, the command palette or ⇧⌘N: a GS Code tab is the only window.
  public static func patchedWorkbench(_ js: String) -> String {
    js.replacingOccurrences(of: #"nameShort:"(?:VSCodium|Glance Studio|Glance Code)",nameLong:"(?:VSCodium|Glance Studio|Glance Code)""#,
                            with: #"nameShort:"GS Code",nameLong:"GS Code""#, options: .regularExpression)
      .replacingOccurrences(
        of: #"(id:"workbench\.action\.newWindow",title:\{[^}]*\}),f1:!0,keybinding:\{[^}]*\},menu:\{[^}]*\}"#,
        with: "$1,f1:!1", options: .regularExpression)
  }

  /// The UI's messages ("Please restart VSCodium…"), renamed; links to VSCodium's pages stay as they are. Installs
  /// patched while the editor was still called Glance Studio or Glance Code get the new name too.
  public static func brandedMessages(_ text: String) -> String {
    text.replacingOccurrences(of: #"(?<![/\w.@-])VSCodium(?![/\w-])|Glance Studio|Glance Code"#, with: "GS Code", options: .regularExpression)
  }

  public struct PortChoice: Equatable, Sendable {
    public let port: Int
    /// A port was saved before and the server can't have it any more, so the editor's stored UI state stays behind.
    public let moved: Bool
    public init(port: Int, moved: Bool) {
      self.port = port
      self.moved = moved
    }
  }

  /// The saved port while it's free, else the first free one in `ports`. Nil when every port is taken.
  public static func choosePort(saved: Int?, isFree: (Int) -> Bool) -> PortChoice? {
    if let saved, ports.contains(saved), isFree(saved) { return PortChoice(port: saved, moved: false) }
    guard let port = ports.first(where: isFree) else { return nil }
    return PortChoice(port: port, moved: saved != nil)
  }

  /// The hex SHA-256 of a file, read 1 MB at a time.
  public static func sha256(of file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// The server's environment: the app's, without Claude Code's session markers (a `claude` started from an
  /// extension would otherwise think it's a child session) but with Glance's mods (ClaudeMods), with the login
  /// shell's PATH so extensions find the same tools as a terminal, and the bridge socket for the Glance extension.
  public static func environment(base: [String: String], path: String?, bridge: String) -> [String: String] {
    var env = base
    for key in ClaudeMods.sessionMarkers(in: base) { env[key] = nil }
    if let path { env["PATH"] = path }
    env["GLANCE_BRIDGE"] = bridge
    return env
  }

  /// Printed on both sides of `$PATH` by the login shell, so greetings and other noise can be ignored.
  public static let pathMarker = "__GLANCE_PATH__"

  public static func pathFromShellOutput(_ output: String) -> String? {
    let parts = output.components(separatedBy: pathMarker)
    guard parts.count >= 3 else { return nil }
    let path = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? nil : path
  }
}
