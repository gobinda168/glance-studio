import CryptoKit
import Foundation

/// Glance's Claude Code plugin (spec 2026-10-09-automations-design.md, "Plugin dir"): the glance-automations skill
/// with its references and starters, and the Glance MCP server. Studio writes it to
/// `~/Library/Application Support/Glance/ClaudePlugin/` (`ClaudePluginDir`) and every `claude` it starts loads it
/// through `CLAUDE_CODE_PLUGIN_DIRS`, so nothing goes into `~/.claude`.
public enum AutomationPlugin {
  public static let name = "glance"
  public static let skillName = "glance-automations"
  public static let skillFolder = "skills/glance-automations"
  /// The plugin's version: bump it when the files change in a way Claude Code should notice.
  public static let version = "1.0.0"

  /// Every file of the plugin, path → text. `cli` is the absolute path of the glance CLI the MCP server runs.
  public static func files(cli: String) -> [String: String] {
    var files: [String: String] = [
      ".claude-plugin/plugin.json": pluginJSON,
      ".mcp.json": mcpJSON(cli: cli),
      "\(skillFolder)/SKILL.md": AutomationPluginDocs.skill(cli: cli),
      "\(skillFolder)/references/manifest.md": AutomationPluginDocs.manifest,
      "\(skillFolder)/references/events.md": AutomationEvents.markdown(),
      "\(skillFolder)/references/ui.md": AutomationPluginDocs.ui,
    ]
    for (id, package) in AutomationStarters.all {
      for (path, text) in package { files["\(skillFolder)/references/starters/\(id)/\(path)"] = text }
    }
    return files
  }

  public static var pluginJSON: String {
    AutomationValue.object([
      "name": .string(name), "version": .string(version),
      "description": .string("Glance Studio automations: the glance-automations skill and the Glance MCP server "
                               + "(search, run and save automations)."),
      "author": .object(["name": .string("Glance")]),
    ]).json + "\n"
  }

  /// The server runs `<cli> automation mcp`.
  public static func mcpJSON(cli: String) -> String {
    AutomationValue.object(["mcpServers": .object([
      "glance": .object(["command": .string(cli), "args": .array([.string("automation"), .string("mcp")])]),
    ])]).json + "\n"
  }

  /// SHA-256 (hex) of every path and text: Studio rewrites the folder only when this changes.
  public static func contentHash(_ files: [String: String]) -> String {
    var hasher = SHA256()
    for path in files.keys.sorted() {
      hasher.update(data: Data(path.utf8))
      hasher.update(data: Data([0]))
      hasher.update(data: Data(files[path]!.utf8))
      hasher.update(data: Data([0]))
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// Whether `text` is a plugin manifest of Glance's own plugin (its `name` is "glance").
  public static func isGlancePluginManifest(_ text: String) -> Bool {
    AutomationValue.decode(Data(text.utf8))?.object?["name"] == .string(name)
  }

  /// Whether `path` lies inside an application bundle (`….app/…`): only an installed Studio may point its plugin
  /// folder at itself; a development build of the CLI must not.
  public static func isInsideAppBundle(_ path: String) -> Bool {
    path.split(separator: "/").dropLast().contains { $0.hasSuffix(".app") }
  }
}
