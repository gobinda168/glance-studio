import Foundation
import GlanceCore

/// Studio's per-launch Claude Code folders in Caches (`~/Library/Caches/Glance Studio`): `session-links` (emptied each
/// launch: no `claude` outlives Studio's shells) and `plugins/glance-humanize` (written fresh from styles/humanize.md).
/// Prepared in main.swift before the first shell starts.
public enum StudioClaudeFolders {
  static let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Glance Studio")
  public static let linksFolder = base.appendingPathComponent("session-links")
  nonisolated(unsafe) public private(set) static var humanizeDir: URL?

  public static func prepare() {
    let fm = FileManager.default
    try? fm.removeItem(at: linksFolder)
    try? fm.createDirectory(at: linksFolder, withIntermediateDirectories: true)
    let plugin = base.appendingPathComponent("plugins/\(HumanizePlugin.name)")
    try? fm.removeItem(at: plugin)
    guard let style = try? String(contentsOf: Resources.outputStyle, encoding: .utf8) else { return }
    for (path, contents) in HumanizePlugin.files(style: style) {
      let url = plugin.appendingPathComponent(path)
      guard (try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil,
            (try? Data(contents.utf8).write(to: url, options: .atomic)) != nil else { return }
    }
    humanizeDir = plugin
  }

  /// The env a new terminal's shell gets (SurfaceView_AppKit), read with the current Response style and the mods that
  /// are on (ModStore).
  public static func environment(for surface: UUID) -> [String: String] {
    let processDirs = ProcessInfo.processInfo.environment[ClaudeMods.pluginDirsKey]
    var environment = SurfaceClaudeEnvironment.make(surface: surface, linksFolder: linksFolder.path, style: Prefs.responseStyle,
                                                    inheritedPluginDirs: processDirs, humanizeDir: humanizeDir?.path)
    // Empty when nothing is on: a missing variable would leave the launch-time value in the shell.
    environment[ClaudeMods.pluginDirsKey] = ModStore.pluginDirs(inherited: environment[ClaudeMods.pluginDirsKey] ?? processDirs) ?? ""
    return environment
  }
}
