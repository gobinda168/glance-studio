import CoreGraphics
import Foundation

/// Glance browser (spec 2026-10-14-agent-browser-design.md): a headless Chromium that Claude Code and Playwright
/// tests drive, shown live in a floating panel. This file is the pure part: versions, the broker's events, the
/// panel's sizes, the ports and CDP's wire format.

/// Glance's own Playwright, installed on first use in Application Support (never bundled: Chromium alone is 150 MB).
public enum AgentBrowserPackages {
  /// Keep in step with `GLANCE_PINS` in agent-browser/agent-browser.mjs.
  public static let playwrightCore = "1.64.1"
  public static let mcp = "0.0.83"

  public static func folder(home: String) -> String {
    (home as NSString).appendingPathComponent("Library/Application Support/Glance/agent-browser")
  }

  /// The two fixed ports Studio listens on (`AgentBrowserPorts.Pair` as JSON), for `glance agent-browser mcp`.
  public static func portsFile(home: String) -> String {
    (folder(home: home) as NSString).appendingPathComponent("ports.json")
  }

  public static func mcpScript(home: String) -> String {
    (folder(home: home) as NSString).appendingPathComponent("node_modules/@playwright/mcp/cli.js")
  }
}

/// A Playwright client says its version in its WebSocket `user-agent` ("Playwright/1.58.2 (arm64; macOS 27.0) …"), and
/// its browser server must be the same version.
public enum PlaywrightClientVersion {
  public static func parse(userAgent: String?) -> String? {
    guard let userAgent, userAgent.hasPrefix("Playwright/") else { return nil }
    let version = userAgent.dropFirst("Playwright/".count).prefix { $0 != " " }
    let parts = version.split(separator: "-", maxSplits: 1)
    guard let core = parts.first, core.split(separator: ".").count == 3,
          core.split(separator: ".").allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
    return String(version)
  }
}

/// One JSON line from the broker's stdout.
public enum AgentBrowserEvent: Equatable, Sendable {
  public enum Kind: String, Sendable { case claude, test }

  case ready(clientPort: Int, cdpPort: Int)
  case installing(what: String)
  case browser(id: String, kind: Kind, version: String, cdpPort: Int)
  case browserGone(id: String)
  case stopped
  case resumed
  case error(String)

  public static func parse(line: String) -> AgentBrowserEvent? {
    guard let json = JSONValue.parse(line), let event = json["event"]?.string else { return nil }
    switch event {
    case "ready":
      guard let client = json["clientPort"]?.int, let cdp = json["cdpPort"]?.int else { return nil }
      return .ready(clientPort: client, cdpPort: cdp)
    case "installing":
      return json["what"]?.string.map { .installing(what: $0) }
    case "browser":
      guard let id = json["id"]?.string, let kind = json["kind"]?.string.flatMap(Kind.init(rawValue:)),
            let version = json["version"]?.string, let port = json["cdpPort"]?.int else { return nil }
      return .browser(id: id, kind: kind, version: version, cdpPort: port)
    case "browserGone":
      return json["id"]?.string.map { .browserGone(id: $0) }
    case "stopped": return .stopped
    case "resumed": return .resumed
    case "error":
      return json["message"]?.string.map { .error($0) }
    default: return nil
    }
  }
}

/// The panel's view ⇄ the page: Claude's pages take the view's size; test pages keep theirs and are letterboxed.
public enum AgentBrowserFit {
  static let minSide = 200
  static let maxSide = 4096

  /// CSS pixels and device scale for `Emulation.setDeviceMetricsOverride`.
  public static func metrics(view: CGSize, scale: CGFloat) -> (width: Int, height: Int, scale: Double) {
    func clamp(_ value: CGFloat) -> Int { min(maxSide, max(minSide, Int(value.rounded()))) }
    return (clamp(view.width), clamp(view.height), scale > 0 ? Double(scale) : 1)
  }

  /// Where a frame of `frame` size is drawn in `bounds`, keeping its aspect ratio, centred.
  public static func aspectFit(frame: CGSize, in bounds: CGRect) -> CGRect {
    guard frame.width > 0, frame.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
    let ratio = min(bounds.width / frame.width, bounds.height / frame.height)
    let size = CGSize(width: frame.width * ratio, height: frame.height * ratio)
    return CGRect(x: bounds.minX + (bounds.width - size.width) / 2, y: bounds.minY + (bounds.height - size.height) / 2,
                  width: size.width, height: size.height)
  }

  /// A point in the view (top-left origin) → the page's CSS pixels; nil outside the drawn frame.
  public static func pagePoint(_ point: CGPoint, shown: CGRect, page: CGSize) -> CGPoint? {
    guard shown.contains(point), shown.width > 0, shown.height > 0 else { return nil }
    return CGPoint(x: (point.x - shown.minX) / shown.width * page.width,
                   y: (point.y - shown.minY) / shown.height * page.height)
  }
}

/// Two fixed local ports, kept across launches so `PW_TEST_CONNECT_WS_ENDPOINT` and the MCP config never change:
/// Playwright clients, then CDP.
public enum AgentBrowserPorts {
  public struct Pair: Equatable, Sendable, Codable {
    public let client: Int
    public let cdp: Int
    public init(client: Int, cdp: Int) { self.client = client; self.cdp = cdp }
  }

  public static let first = 9322

  public static func choose(saved: (Int, Int)?, isFree: (Int) -> Bool) -> Pair? {
    if let saved, isFree(saved.0), isFree(saved.1) { return Pair(client: saved.0, cdp: saved.1) }
    var port = first
    while port < first + 200 {
      if isFree(port), isFree(port + 1) { return Pair(client: port, cdp: port + 1) }
      port += 2
    }
    return nil
  }
}

/// Chrome DevTools Protocol messages (flat sessions: a target's commands carry its `sessionId`).
public enum CDPMessage: Equatable, Sendable {
  case response(id: Int, result: JSONValue?, error: String?)
  case event(method: String, params: JSONValue, sessionId: String?)

  public static func command(id: Int, method: String, params: JSONValue = [:], sessionId: String? = nil) -> Data {
    var message: [String: JSONValue] = ["id": .number(Double(id)), "method": .string(method), "params": params]
    if let sessionId { message["sessionId"] = .string(sessionId) }
    return Data(JSONValue.object(message).text.utf8)
  }

  public static func parse(_ text: String) -> CDPMessage? {
    guard let json = JSONValue.parse(text) else { return nil }
    if let id = json["id"]?.int {
      return .response(id: id, result: json["result"], error: json["error"]?["message"]?.string)
    }
    guard let method = json["method"]?.string else { return nil }
    return .event(method: method, params: json["params"] ?? [:], sessionId: json["sessionId"]?.string)
  }
}
