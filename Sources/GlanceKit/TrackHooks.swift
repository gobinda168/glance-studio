import Foundation
import GlanceCore

/// Turns the tracking hooks on or off in ~/.claude/settings.json. Glance Studio calls it as `Feature.worktrees`
/// changes; `glance track-hooks` and `glance unsetup` call it too. The hooks run ~/.claude/glance/track.sh, which runs
/// `glance` only while it exists.
public enum TrackHooks {
  /// On: writes the wrapper script for `glance` and adds the hooks. Off: removes the hooks, then the script. The
  /// first change backs settings.json up to settings.json.glance-backup; an existing backup is never overwritten.
  public static func set(on: Bool, glance: String, options: TrackHookSetup.Options = [.changes],
                         paths: ClaudeSetup.Paths = .init()) throws {
    let fm = FileManager.default
    let data = fm.contents(atPath: paths.settings.path)
    let settings = try data.map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] ?? [:] } ?? [:]
    if on {
      try ExecutableScript.write(TrackHookSetup.script(glance: glance, options: options), to: paths.trackScript)
    }
    let after = on ? TrackHookSetup.install(into: settings, script: paths.trackScript.path)
      : TrackHookSetup.uninstall(from: settings)
    if !NSDictionary(dictionary: after).isEqual(to: settings) {
      if fm.fileExists(atPath: paths.settings.path), !fm.fileExists(atPath: paths.backup.path) {
        try fm.copyItem(at: paths.settings, to: paths.backup)
      }
      try fm.createDirectory(at: paths.claude, withIntermediateDirectories: true)
      try JSONSerialization.data(withJSONObject: after, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        .write(to: paths.settings, options: .atomic)
    }
    // Only once no hook runs it.
    if !on, fm.fileExists(atPath: paths.trackScript.path) { try fm.removeItem(at: paths.trackScript) }
  }

  /// What the installed wrapper script does (its flags), or nil when it isn't installed.
  public static func installedOptions(paths: ClaudeSetup.Paths = .init()) -> TrackHookSetup.Options? {
    (try? String(contentsOf: paths.trackScript, encoding: .utf8)).map(TrackHookSetup.Options.init(script:))
  }

  /// Whether the installed tracking hooks observe proof (the script carries --work): the MCP shim's switch for
  /// listing the proof tools.
  public static func workOn(paths: ClaudeSetup.Paths = .init()) -> Bool {
    installedOptions(paths: paths)?.contains(.work) ?? false
  }

  public static func isOn(paths: ClaudeSetup.Paths = .init()) -> Bool {
    guard let data = FileManager.default.contents(atPath: paths.settings.path),
          let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
    return TrackHookSetup.isInstalled(in: settings)
  }
}

/// The one serial queue Glance Studio writes Claude Code's settings.json on (the tracking hooks, the first-launch
/// setup), so two read-modify-writes never interleave and lose each other's change.
public enum ClaudeSettingsQueue {
  public static let shared = DispatchQueue(label: "glance.claude-settings")
}
