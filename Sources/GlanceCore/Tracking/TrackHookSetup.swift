import Foundation

/// The tracking hooks in Claude Code's settings JSON (spec §1, "Hooks"): one `<track.sh> <Event>` per event, marked
/// `# glance-track` so they are added and removed apart from Glance's notify hooks (`HookSetup`, `# glance`). The
/// script runs `glance track <Event>`, and does nothing when that `glance` is gone (a moved app, a deleted build), so
/// Claude Code never sees a failing hook.
public enum TrackHookSetup {
  /// A Bash call that exits non-zero is a PostToolUseFailure, not a PostToolUse: proof of work needs both.
  public static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                              "SessionEnd"]
  public static let marker = "# glance-track"
  /// Seconds Claude Code gives a tracking hook before it moves on.
  public static let timeout = 10

  /// What the hooks do. The CLI never reads Studio's feature flags: Studio writes them into the wrapper script.
  public struct Options: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// Change tracking (Feature.worktrees): fingerprints on tool calls, warnings for Claude.
    public static let changes = Options(rawValue: 1)
    /// Proof of work (Feature.commandCenter): observe checks and browser screenshots.
    public static let work = Options(rawValue: 2)

    /// What the hooks do for the two features that need them: change tracking while Worktrees is on, proof of work
    /// while Command Center is on. Empty (no hooks at all) only when both are off, so turning one off with the other
    /// still on keeps the hooks, with the other's flags.
    public init(worktrees: Bool, commandCenter: Bool) {
      var options: Options = []
      if worktrees { options.insert(.changes) }
      if commandCenter { options.insert(.work) }
      self = options
    }

    /// The options a wrapper script's text carries (`--sessions-only` means no change tracking, `--work` proof).
    public init(script: String) {
      // Only the flags after the exec line count: the glance path above them may contain anything.
      let exec = script.split(separator: "\n").last { $0.hasPrefix("exec ") }.map(String.init) ?? ""
      let flags = exec.split(separator: " ")
      var options: Options = []
      if !flags.contains("--sessions-only") { options.insert(.changes) }
      if flags.contains("--work") { options.insert(.work) }
      self = options
    }
  }

  /// The wrapper script's text, for `glance` at that path.
  public static func script(glance: String, options: Options = [.changes]) -> String {
    var flags = ""
    if !options.contains(.changes) { flags += " --sessions-only" }
    if options.contains(.work) { flags += " --work" }
    return """
    #!/bin/sh
    # Glance's change tracking (glance track). Does nothing if Glance moved or was deleted.
    g=\(quoted(glance))
    [ -x "$g" ] || exit 0
    exec "$g" track "$1"\(flags)

    """
  }

  public static func command(script: String, event: String) -> String {
    "\(quoted(script)) \(event) \(marker)"
  }

  /// `text` in single quotes for sh.
  static func quoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  public static func install(into settings: [String: Any], script: String) -> [String: Any] {
    var settings = uninstall(from: settings)
    var hooks = settings["hooks"] as? [String: Any] ?? [:]
    for event in events {
      var entries = hooks[event] as? [[String: Any]] ?? []
      entries.append(["hooks": [["type": "command", "command": command(script: script, event: event),
                                 "timeout": timeout]]])
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

  public static func isInstalled(in settings: [String: Any]) -> Bool {
    let hooks = settings["hooks"] as? [String: Any] ?? [:]
    return events.allSatisfy { event in
      (hooks[event] as? [[String: Any]] ?? []).contains { entry in
        (entry["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.hasSuffix(marker) ?? false }
      }
    }
  }
}
