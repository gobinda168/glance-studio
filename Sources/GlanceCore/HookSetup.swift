import Foundation

/// Adds and removes Glance's hook entries in Claude Code's settings JSON, leaving everything else alone.
public enum HookSetup {
  public static let events = ["UserPromptSubmit", "Stop"]
  /// Suffix that marks a hook command as Glance's own.
  public static let marker = "# glance"

  public static func install(into settings: [String: Any], command: String) -> [String: Any] {
    var settings = uninstall(from: settings)
    var hooks = settings["hooks"] as? [String: Any] ?? [:]
    for event in events {
      var entries = hooks[event] as? [[String: Any]] ?? []
      entries.append(["hooks": [["type": "command", "command": command]]])
      hooks[event] = entries
    }
    settings["hooks"] = hooks
    return settings
  }

  public static func uninstall(from settings: [String: Any]) -> [String: Any] {
    var settings = settings
    guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
    for event in events {
      guard let entries = hooks[event] as? [[String: Any]] else { continue }
      let kept = entries.compactMap { entry -> [String: Any]? in
        guard let commands = entry["hooks"] as? [[String: Any]] else { return entry }
        let foreign = commands.filter { !(($0["command"] as? String)?.hasSuffix(marker) ?? false) }
        if foreign.isEmpty { return nil }
        var entry = entry
        entry["hooks"] = foreign
        return entry
      }
      hooks[event] = kept.isEmpty ? nil : kept
    }
    settings["hooks"] = hooks.isEmpty ? nil : hooks
    return settings
  }

  /// Whether every Glance event has Glance's hook.
  public static func isInstalled(in settings: [String: Any]) -> Bool {
    let hooks = settings["hooks"] as? [String: Any] ?? [:]
    return events.allSatisfy { event in
      (hooks[event] as? [[String: Any]] ?? []).contains { entry in
        (entry["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.hasSuffix(marker) ?? false }
      }
    }
  }

  public static func command(forScript path: String) -> String {
    "'\(path.replacingOccurrences(of: "'", with: "'\\''"))' \(marker)"
  }
}
