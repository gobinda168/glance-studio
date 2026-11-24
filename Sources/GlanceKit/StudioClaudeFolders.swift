import Foundation
import GlanceCore

/// Studio's per-launch Claude Code folders in Caches (`~/Library/Caches/Glance Studio`): `session-links-<pid>` (one per
/// running Studio, new each launch: no `claude` outlives Studio's shells) and `plugins/glance-humanize` (written fresh
/// from styles/humanize.md). Prepared in main.swift before the first shell starts.
public enum StudioClaudeFolders {
  static let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Glance Studio")
  private static let linksPrefix = "session-links-"
  public static let linksFolder = linksFolder(in: base, pid: ProcessInfo.processInfo.processIdentifier)
  nonisolated(unsafe) public private(set) static var humanizeDir: URL?

  /// This launch's links folder, empty. A folder another running Studio holds is left alone: removing it would leave
  /// that Studio watching a deleted folder. Only the folders of Studios that are gone are swept.
  @discardableResult
  static func prepareLinksFolder(in base: URL, pid: Int32, isAlive: (Int32) -> Bool) -> URL {
    let fm = FileManager.default
    for name in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] where name.hasPrefix(linksPrefix) {
      guard let owner = Int32(name.dropFirst(linksPrefix.count)), owner == pid || !isAlive(owner) else { continue }
      try? fm.removeItem(at: base.appendingPathComponent(name))
    }
    let folder = linksFolder(in: base, pid: pid)
    try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  private static func linksFolder(in base: URL, pid: Int32) -> URL {
    base.appendingPathComponent(linksPrefix + String(pid))
  }

  private static func isRunning(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
  }

  public static func prepare() {
    let fm = FileManager.default
    prepareLinksFolder(in: base, pid: ProcessInfo.processInfo.processIdentifier, isAlive: isRunning)
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
