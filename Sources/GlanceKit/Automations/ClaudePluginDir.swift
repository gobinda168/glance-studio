import Foundation
import GlanceCore

/// Writes Glance's Claude Code plugin (`AutomationPlugin`: the glance-automations skill and the Glance MCP server) to
/// `~/Library/Application Support/Glance/ClaudePlugin/` (spec 2026-10-09-automations-design.md, "Plugin dir") and
/// puts it on `CLAUDE_CODE_PLUGIN_DIRS`, the way `ClaudeMods` loads Glance's mods: every `claude` Studio starts (its
/// terminals, Razor Chat, the builder tab) loads it, and `~/.claude` never sees it.
public enum ClaudePluginDir {
  /// The content hash of what was written, beside the files.
  static let hashFile = ".glance-content-hash"

  /// ~/Library/Application Support/Glance/ClaudePlugin
  public static var standard: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Glance/ClaudePlugin", isDirectory: true)
  }

  /// Whether `folder` may be written: it doesn't exist, is empty, or is a folder this installer wrote before (it holds
  /// the content hash file, or a plugin manifest named "glance"). Anything else is somebody's folder.
  public static func isUsable(_ folder: URL) -> Bool {
    let manager = FileManager.default
    var isDirectory: ObjCBool = false
    guard manager.fileExists(atPath: folder.path, isDirectory: &isDirectory) else { return true }
    guard isDirectory.boolValue, let names = try? manager.contentsOfDirectory(atPath: folder.path) else { return false }
    if names.isEmpty || names.contains(hashFile) { return true }
    let manifest = try? String(contentsOf: folder.appendingPathComponent(".claude-plugin/plugin.json"), encoding: .utf8)
    return manifest.map(AutomationPlugin.isGlancePluginManifest) ?? false
  }

  /// Removes the half-written siblings (`.ClaudePlugin-<uuid>`) an install that died left in `parent`, once they are an
  /// hour old (a younger one may be another process's install in progress).
  static func sweepStale(in parent: URL, prefix: String) {
    let manager = FileManager.default
    let names = (try? manager.contentsOfDirectory(atPath: parent.path)) ?? []
    for name in names where name.hasPrefix(prefix) && name.count == prefix.count + 36 {
      let url = parent.appendingPathComponent(name)
      let modified = (try? manager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
      if let modified, Date().timeIntervalSince(modified) > 3600 { try? manager.removeItem(at: url) }
    }
  }

  /// Writes the plugin into `folder` when its content changed (or isn't there), and returns the folder; nil when it
  /// couldn't be written, or when `folder` exists and isn't a Glance plugin folder or empty (nothing is written then).
  /// A new version goes into a sibling folder first and then takes the old one's place, so a Claude reading the skill
  /// never sees half of it.
  @discardableResult
  public static func install(cli: String, at folder: URL = standard) -> URL? {
    guard isUsable(folder) else {
      NSLog("Glance: \(folder.path) isn't a Glance plugin folder; leaving it alone")
      return nil
    }
    let files = AutomationPlugin.files(cli: cli)
    let hash = AutomationPlugin.contentHash(files)
    let manager = FileManager.default
    let written = try? String(contentsOf: folder.appendingPathComponent(hashFile), encoding: .utf8)
    if written == hash, manager.fileExists(atPath: folder.appendingPathComponent(".claude-plugin/plugin.json").path) {
      return folder
    }
    let parent = folder.deletingLastPathComponent()
    sweepStale(in: parent, prefix: ".\(folder.lastPathComponent)-")
    let fresh = parent.appendingPathComponent(".\(folder.lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
    do {
      try manager.createDirectory(at: fresh, withIntermediateDirectories: true)
      for (path, text) in files {
        let url = fresh.appendingPathComponent(path)
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
      }
      try Data(hash.utf8).write(to: fresh.appendingPathComponent(hashFile))
      if manager.fileExists(atPath: folder.path) {
        _ = try manager.replaceItemAt(folder, withItemAt: fresh)
      } else {
        try manager.moveItem(at: fresh, to: folder)
      }
      return folder
    } catch {
      NSLog("Glance: couldn't write the Claude plugin to \(folder.path): \(error.localizedDescription)")
      try? manager.removeItem(at: fresh)
      return nil
    }
  }

  /// Installs the plugin and adds it to `CLAUDE_CODE_PLUGIN_DIRS` in this process, so every process started from now
  /// on (libghostty's shells copy the environment at `ghostty_init`, so call this before it) loads it.
  @discardableResult
  public static func export(cli: String, at folder: URL = standard) -> URL? {
    guard let folder = install(cli: cli, at: folder) else { return nil }
    let key = ClaudeMods.pluginDirsKey
    let existing = getenv(key).map { String(cString: $0) }
    if let value = ClaudeMods.pluginDirs(adding: [folder], to: existing), value != existing { setenv(key, value, 1) }
    return folder
  }
}
