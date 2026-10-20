import Foundation

/// The MCP side of `glance mcp` (spec 2026-10-09-orb-channel-design.md, "What Claude Code gives us"): JSON-RPC 2.0, one
/// message per line on stdin/stdout. Claude Code is the client; Glance answers `initialize`, `tools/list` and
/// `tools/call`, and sends the channel notifications.
public enum MCP {
  public static let protocolVersion = "2025-06-18"
  public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
  /// Glance → session: a message from the user (needs the session launched with the channel flag).
  public static let channelMethod = "notifications/claude/channel"
  /// Session → Glance: a permission prompt the user may answer from the orb.
  public static let permissionRequestMethod = "notifications/claude/channel/permission_request"
  /// Glance → session: the user's verdict on a permission prompt.
  public static let permissionVerdictMethod = "notifications/claude/channel/permission"

  public enum Incoming: Equatable, Sendable {
    case request(id: JSONValue, method: String, params: JSONValue)
    case notification(method: String, params: JSONValue)
    /// A reply to something Glance sent; Glance sends no requests, so these are ignored.
    case response(id: JSONValue)
    case invalid
  }

  public static func parse(_ line: String) -> Incoming {
    guard let message = JSONValue.parse(line), let object = message.object, object["jsonrpc"] == "2.0" else {
      return .invalid
    }
    let params = object["params"] ?? [:]
    switch (object["method"]?.string, object["id"]) {
    case (let method?, let id?) where id != .null: return .request(id: id, method: method, params: params)
    case (let method?, _): return .notification(method: method, params: params)
    case (nil, let id?): return .response(id: id)
    default: return .invalid
    }
  }

  public static func result(id: JSONValue, _ result: JSONValue) -> String {
    JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result]).text
  }

  public static func error(id: JSONValue, code: Int, message: String) -> String {
    JSONValue.object(["jsonrpc": "2.0", "id": id,
                      "error": ["code": .number(Double(code)), "message": .string(message)]]).text
  }

  public static func notification(method: String, params: JSONValue) -> String {
    JSONValue.object(["jsonrpc": "2.0", "method": .string(method), "params": params]).text
  }

  /// The client's version when Glance speaks it, else Glance's newest.
  public static func initializeResult(clientVersion: String?, serverVersion: String) -> JSONValue {
    let version = clientVersion.flatMap { supportedVersions.contains($0) ? $0 : nil } ?? protocolVersion
    return [
      "protocolVersion": .string(version),
      "capabilities": ["tools": [:], "experimental": ["claude/channel": [:], "claude/channel/permission": [:]]],
      "serverInfo": ["name": "glance", "version": .string(serverVersion)],
      "instructions": .string(instructions),
    ]
  }

  /// A tool's answer: one text block (a JSON value as its text; a plain string as itself).
  public static func toolResult(_ value: JSONValue, isError: Bool = false) -> JSONValue {
    ["content": [["type": "text", "text": .string(value.string ?? value.text)]], "isError": .bool(isError)]
  }

  /// What Claude reads about the server: when to use each tool.
  public static let instructions = """
    Glance is the user's Mac companion. These tools reach the user even when they aren't watching this terminal: \
    cards at the top of their screen, the glowing orb, and Glance's voice. Use ask when you're blocked on a decision \
    and the user may be away; it waits for their answer (a click, typed text, or speech) and returns it. If it \
    returns status "pending", carry on with other work and call check_answer later. Use status during long tasks \
    (working, then done or error). Use nudge when something finishes or fails and the user should know; give it \
    actions only when you'll act on the choice. Use tell when the user asked to be told something ("let me know \
    when the build is done"): it opens Glance's card beside the orb with your markdown and reads it aloud; keep nudge \
    for alerts. Use speak sparingly, for one or two sentences worth hearing. \
    Messages from the user can arrive as <channel source="glance"> events: treat them as the user's own words.
    """
}
