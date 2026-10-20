import Foundation

/// Registers `glance mcp` with Claude Code (spec "Setup and Settings"). Always through `claude mcp …`, which owns
/// `~/.claude.json`; Glance only reads that file to show the status.
public enum MCPSetup {
  public enum Status: Equatable, Sendable {
    case missing
    case registered(command: String)
    /// A server named "glance" that isn't Glance's.
    case other(String)
  }

  public static func addArguments(glancePath: String) -> [String] {
    let config: JSONValue = ["type": "stdio", "command": .string(glancePath), "args": ["mcp"]]
    return ["mcp", "add-json", "--scope", "user", "glance", config.text]
  }

  public static let removeArguments = ["mcp", "remove", "--scope", "user", "glance"]

  /// From `~/.claude.json`'s user-scope `mcpServers`.
  public static func registered(claudeJSON: Data?) -> Status {
    guard let data = claudeJSON, let root = JSONValue.parse(String(decoding: data, as: UTF8.self)),
          let server = root["mcpServers"]?["glance"], let command = server["command"]?.string else { return .missing }
    let args = server["args"]?.array?.compactMap(\.string) ?? []
    if args == ["mcp"] && command.hasSuffix("/glance") { return .registered(command: command) }
    return .other(([command] + args).joined(separator: " "))
  }
}

/// Registers `glance agent-browser mcp` as the "glance-browser" MCP server (spec 2026-10-14-agent-browser-design.md):
/// the Playwright MCP on the Glance browser, which Studio shows in a floating panel.
public enum BrowserMCPSetup {
  public static let name = "glance-browser"

  public static func addArguments(glancePath: String) -> [String] {
    let config: JSONValue = ["type": "stdio", "command": .string(glancePath), "args": ["agent-browser", "mcp"]]
    return ["mcp", "add-json", "--scope", "user", name, config.text]
  }

  public static let removeArguments = ["mcp", "remove", "--scope", "user", name]

  public static func registered(claudeJSON: Data?) -> MCPSetup.Status {
    guard let data = claudeJSON, let root = JSONValue.parse(String(decoding: data, as: UTF8.self)),
          let server = root["mcpServers"]?[name], let command = server["command"]?.string else { return .missing }
    let args = server["args"]?.array?.compactMap(\.string) ?? []
    if args == ["agent-browser", "mcp"] && command.hasSuffix("/glance") { return .registered(command: command) }
    return .other(([command] + args).joined(separator: " "))
  }
}
