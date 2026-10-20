import Foundation

/// Whether Claude Code can reach Slack (spec 2026-10-09-notifications-design.md, "Slack MCP detection"): read from the
/// first stream-json line of a `claude` run, its `system`/`init` event, which lists the MCP servers and their tools.
public enum SlackMCP {
  public struct Status: Equatable, Sendable {
    public let connected: Bool
    /// The connected server's name ("claude.ai Slack").
    public let server: String?
    /// Tools that only read (threads, search, history): the resolve and AI runs get these.
    public let readTools: [String]
    /// Tools that post a message or reply: only the Send run gets these.
    public let sendTools: [String]
    /// Every tool of the Slack server, read, send or other (canvases, reactions…).
    public let tools: [String]
    /// The Slack server was still connecting when the run started (claude.ai connectors often are): not connected
    /// yet, its tools not listed, worth asking again.
    public let pending: Bool

    public init(connected: Bool, server: String?, readTools: [String], sendTools: [String], tools: [String]? = nil,
                pending: Bool = false) {
      self.connected = connected
      self.server = server
      self.readTools = readTools
      self.sendTools = sendTools
      self.tools = tools ?? readTools + sendTools
      self.pending = pending
    }

    public static let disconnected = Status(connected: false, server: nil, readTools: [], sendTools: [])

    /// The Slack tools a run must not use when it may use only `allowed`: a `claude` run passes them as
    /// `--disallowedTools`, so a step can't reach another tool even when the user's settings pre-allow it.
    public func disallowed(allowing allowed: [String]) -> [String] {
      tools.filter { !allowed.contains($0) }
    }
  }

  /// Words that mark a tool as one that changes something; a read tool has none of them.
  private static let writeWords = ["send", "post", "update", "delete", "react", "schedule", "create", "canvas"]

  /// From the first stream-json line (`{"type":"system","subtype":"init",…}`). Nil when the line isn't that event.
  public static func status(initLine: String) -> Status? {
    guard let object = try? JSONSerialization.jsonObject(with: Data(initLine.utf8)) as? [String: Any],
          object["type"] as? String == "system", object["subtype"] as? String == "init" else { return nil }
    let slack = (object["mcp_servers"] as? [[String: Any]] ?? []).filter {
      ($0["name"] as? String)?.localizedCaseInsensitiveContains("slack") == true
    }
    let named = { (status: String) in slack.first { $0["status"] as? String == status }?["name"] as? String }
    guard let server = named("connected") else {
      return named("pending").map { Status(connected: false, server: $0, readTools: [], sendTools: [], pending: true) }
        ?? .disconnected
    }
    let slackTools = (object["tools"] as? [String] ?? []).compactMap { name in
      toolPart(name).map { (name: name, tool: $0) }
    }
    let send = slackTools.filter { isSend($0.tool) }.map(\.name)
    let read = slackTools.filter { tool in !writeWords.contains { tool.tool.contains($0) } }.map(\.name)
    return Status(connected: true, server: server, readTools: read, sendTools: send, tools: slackTools.map(\.name))
  }

  /// The lowercased tool name after `mcp__<server>__`, when the server segment is a Slack one.
  private static func toolPart(_ name: String) -> String? {
    guard name.hasPrefix("mcp__") else { return nil }
    let rest = name.dropFirst("mcp__".count)
    guard let separator = rest.range(of: "__") else { return nil }
    guard rest[..<separator.lowerBound].lowercased().contains("slack") else { return nil }
    return rest[separator.upperBound...].lowercased()
  }

  private static func isSend(_ tool: String) -> Bool {
    (tool.contains("send") || tool.contains("post")) && (tool.contains("message") || tool.contains("reply"))
  }
}
