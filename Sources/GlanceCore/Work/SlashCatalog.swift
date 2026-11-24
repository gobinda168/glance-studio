import Foundation

/// What `/` offers in the Glance composer: Claude Code's own commands plus whatever the user, the project and the
/// installed plugins define on disk (nothing about projects is built in).
public struct SlashCommand: Equatable, Sendable, Identifiable {
  public enum Source: Equatable, Sendable { case builtIn, user, project, plugin(String) }
  public let name: String
  public let summary: String
  public let source: Source
  public var id: String { name }
  public var interactive: Bool { source == .builtIn && SlashCatalog.isInteractive(name) }
  public init(name: String, summary: String, source: Source) { self.name = name; self.summary = summary; self.source = source }
}

public enum SlashCatalog {
  /// Claude Code's built-in commands (its own surface, not project knowledge).
  public static let builtIns: [SlashCommand] = [
    ("add-dir", "Add a working directory"), ("agents", "Manage subagents"), ("clear", "Clear the conversation"),
    ("compact", "Compact the conversation"), ("config", "Open settings"), ("context", "Show context usage"),
    ("cost", "Show this session's cost"), ("doctor", "Check the installation"), ("export", "Export the conversation"),
    ("help", "Show help"), ("hooks", "Manage hooks"), ("init", "Write CLAUDE.md for this project"),
    ("mcp", "Manage MCP servers"), ("memory", "Edit memory files"), ("model", "Pick a model"),
    ("permissions", "Manage permissions"), ("plugin", "Manage plugins"), ("pr-comments", "Show PR comments"),
    ("resume", "Resume a session"), ("review", "Review a pull request"), ("rewind", "Rewind the conversation"),
    ("security-review", "Security review of pending changes"), ("status", "Show status"), ("usage", "Show plan usage"),
  ].map { SlashCommand(name: $0.0, summary: $0.1, source: .builtIn) }

  private static let interactiveNames: Set<String> = [
    "add-dir", "agents", "config", "doctor", "export", "hooks", "mcp", "memory", "model", "permissions", "plugin",
    "resume", "rewind", "status", "usage", "login", "logout", "theme", "ide",
  ]

  public static func isInteractive(_ name: String) -> Bool { interactiveNames.contains(name) }

  public static func scan(home: String, project: String?) -> [SlashCommand] {
    var out: [SlashCommand] = []
    out += commands(in: home + "/.claude/commands", source: .user, prefix: "")
    out += skills(in: home + "/.claude/skills", source: .user, prefix: "")
    if let project {
      out += commands(in: project + "/.claude/commands", source: .project, prefix: "")
      out += skills(in: project + "/.claude/skills", source: .project, prefix: "")
    }

    let settings = loadSettings(at: home + "/.claude/settings.json")

    // Try installed_plugins.json first
    if let plugins = scanInstalledPlugins(home: home, settings: settings) {
      out += plugins
      return out
    }
    // Fall back to cache directory walk only if installed_plugins.json missing or unparseable
    out += scanCachePlugins(cache: home + "/.claude/plugins/cache", settings: settings)
    return out
  }

  private static func loadSettings(at path: String) -> [String: Any] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return [:] }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return json
  }

  private static func scanInstalledPlugins(home: String, settings: [String: Any]) -> [SlashCommand]? {
    let installedPath = home + "/.claude/plugins/installed_plugins.json"
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: installedPath)),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let pluginsDict = json["plugins"] as? [String: [[String: Any]]] else { return nil }

    let enabledPlugins = (settings["enabledPlugins"] as? [String: Bool]) ?? [:]
    var out: [SlashCommand] = []

    for (key, entries) in pluginsDict.sorted(by: { $0.key < $1.key }) {
      let pluginName = key.components(separatedBy: "@").first ?? key
      guard enabledPlugins[key] != false else { continue }

      let newest = entries.max { a, b in
        let dateA = (a["lastUpdated"] as? String) ?? ""
        let dateB = (b["lastUpdated"] as? String) ?? ""
        return dateA < dateB
      }
      guard let entry = newest, let installPath = entry["installPath"] as? String else { continue }

      out += commands(in: installPath + "/commands", source: .plugin(pluginName), prefix: pluginName + ":")
      out += skills(in: installPath + "/skills", source: .plugin(pluginName), prefix: pluginName + ":")
    }
    return out
  }

  private static func scanCachePlugins(cache: String, settings: [String: Any]) -> [SlashCommand] {
    let fm = FileManager.default
    let enabledPlugins = (settings["enabledPlugins"] as? [String: Bool]) ?? [:]
    var out: [SlashCommand] = []

    for market in (try? fm.contentsOfDirectory(atPath: cache)) ?? [] {
      guard !market.hasPrefix(".") else { continue }
      var isDir: ObjCBool = false
      guard fm.fileExists(atPath: "\(cache)/\(market)", isDirectory: &isDir), isDir.boolValue else { continue }

      for plugin in (try? fm.contentsOfDirectory(atPath: "\(cache)/\(market)")) ?? [] {
        guard !plugin.hasPrefix(".") && !plugin.hasPrefix("_") && !plugin.hasPrefix("temp_") else { continue }
        isDir = false
        guard fm.fileExists(atPath: "\(cache)/\(market)/\(plugin)", isDirectory: &isDir), isDir.boolValue else { continue }
        guard enabledPlugins["\(plugin)@\(market)"] != false else { continue }

        let pluginPath = "\(cache)/\(market)/\(plugin)"
        let versions = ((try? fm.contentsOfDirectory(atPath: pluginPath)) ?? [])
          .filter { name in
            guard !name.hasPrefix(".") && !name.hasPrefix("_") && !name.hasPrefix("temp_") else { return false }
            isDir = false
            return fm.fileExists(atPath: "\(pluginPath)/\(name)", isDirectory: &isDir) && isDir.boolValue
          }
          .sorted { $0.compare($1, options: .numeric) == .orderedAscending }

        guard let version = versions.last else { continue }
        let base = "\(cache)/\(market)/\(plugin)/\(version)"
        out += commands(in: base + "/commands", source: .plugin(plugin), prefix: plugin + ":")
        out += skills(in: base + "/skills", source: .plugin(plugin), prefix: plugin + ":")
      }
    }
    return out
  }

  private static func commands(in folder: String, source: SlashCommand.Source, prefix: String) -> [SlashCommand] {
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(".md") }.sorted()
    return files.compactMap { file in
      guard let text = try? String(contentsOfFile: "\(folder)/\(file)", encoding: .utf8) else { return nil }
      return SlashCommand(name: prefix + String(file.dropLast(3)), summary: summary(text), source: source)
    }
  }

  private static func skills(in folder: String, source: SlashCommand.Source, prefix: String) -> [SlashCommand] {
    let dirs = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
    return dirs.compactMap { dir in
      guard let text = try? String(contentsOfFile: "\(folder)/\(dir)/SKILL.md", encoding: .utf8) else { return nil }
      return SlashCommand(name: prefix + (frontmatter(text)["name"] ?? dir), summary: summary(text), source: source)
    }
  }

  /// The description from front matter, else the first non-empty body line.
  private static func summary(_ text: String) -> String {
    if let d = frontmatter(text)["description"] { return d }
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    let body = normalized.hasPrefix("---") ? normalized.components(separatedBy: "\n---").dropFirst().joined(separator: "\n---") : normalized
    return body.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
  }

  public static func frontmatter(_ text: String) -> [String: String] {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    let lines = normalized.components(separatedBy: .newlines)
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
    var out: [String: String] = [:]
    var i = 1
    while i < lines.count {
      let line = lines[i]
      if line.trimmingCharacters(in: .whitespacesAndNewlines) == "---" { break }
      guard let colon = line.firstIndex(of: ":") else { i += 1; continue }
      let key = line[..<colon].trimmingCharacters(in: .whitespaces)
      let valuePart = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)

      // Handle block scalars (>, |, >-, |-)
      if valuePart.isEmpty || valuePart.hasPrefix(">") || valuePart.hasPrefix("|") {
        var scalar = ""
        i += 1
        while i < lines.count {
          let trimmed = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
          if trimmed.isEmpty || trimmed.hasPrefix("---") { break }
          let indent = lines[i].prefix(while: { $0.isWhitespace }).count
          if indent == 0 { break }
          scalar += lines[i].trimmingCharacters(in: .whitespaces) + " "
          i += 1
        }
        if !scalar.isEmpty { out[key] = scalar.trimmingCharacters(in: .whitespaces) }
        continue
      }

      // Handle quoted values
      var value = valuePart
      if value.count >= 2, let f = value.first, f == "\"" || f == "'", value.last == f { value = String(value.dropFirst().dropLast()) }
      out[key] = value
      i += 1
    }
    return out
  }

  public static func matches(_ query: String, in commands: [SlashCommand], limit: Int = 12) -> [SlashCommand] {
    let q = query.lowercased()
    guard !q.isEmpty else { return Array(commands.prefix(limit)) }
    func score(_ c: SlashCommand) -> Int? {
      let n = c.name.lowercased()
      if n.hasPrefix(q) || n.split(separator: ":").last?.hasPrefix(q) == true { return 0 }
      if n.contains(q) { return 1 }
      if c.summary.lowercased().contains(q) { return 2 }
      return nil
    }
    return commands.compactMap { c in score(c).map { (c, $0) } }
      .enumerated().sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }
      .prefix(limit).map(\.element.0)
  }
}
