import Foundation

/// The Claude Code mods Glance Studio ships (`mods/` in the repo, `Resources/mods` in the app): plugin directories
/// every `claude` started in Studio loads through `CLAUDE_CODE_PLUGIN_DIRS`, so `~/.claude` and other terminals never
/// see them.
///
/// Claude Code loads them as it loads `--plugin-dir`, writing type declarations into each one, so they run from a
/// copy outside the app (in Caches): a write inside the app bundle would break its signature.
public enum ClaudeMods {
  public static let pluginDirsKey = "CLAUDE_CODE_PLUGIN_DIRS"

  /// The mod directories under `root`: each one with a `.claude-plugin/plugin.json`, sorted by name.
  public static func bundled(in root: URL, fileManager: FileManager = .default) -> [URL] {
    let entries = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    return entries
      .filter { fileManager.fileExists(atPath: $0.appendingPathComponent(".claude-plugin/plugin.json").path) }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  /// Replaces `destination` with a fresh copy of each mod in `bundle` (so an app update brings the new code), and
  /// returns the copies. A mod that can't be copied is left out.
  public static func install(from bundle: URL, into destination: URL, fileManager: FileManager = .default) -> [URL] {
    try? fileManager.removeItem(at: destination)
    guard (try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)) != nil else { return [] }
    return bundled(in: bundle, fileManager: fileManager).compactMap { mod in
      let copy = destination.appendingPathComponent(mod.lastPathComponent)
      return (try? fileManager.copyItem(at: mod, to: copy)) != nil ? copy : nil
    }
  }

  /// `CLAUDE_CODE_PLUGIN_DIRS` with `dirs` added after what the person set themselves; nil when there's nothing.
  public static func pluginDirs(adding dirs: [URL], to existing: String?) -> String? {
    var paths = (existing ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
    for dir in dirs where !paths.contains(dir.path) { paths.append(dir.path) }
    return paths.isEmpty ? nil : paths.joined(separator: ":")
  }

  /// The variables in `environment` that a Claude Code session sets for what it starts (`CLAUDECODE`,
  /// `CLAUDE_CODE_CHILD_SESSION`, its session id and socket, ...): everything named `CLAUDE*` except
  /// `CLAUDE_CODE_PLUGIN_DIRS`. A `claude` that inherits them thinks it's a child session and saves no transcript.
  public static func sessionMarkers(in environment: [String: String]) -> [String] {
    environment.keys.filter { $0.hasPrefix("CLAUDE") && $0 != pluginDirsKey }.sorted()
  }

  /// The variables in `environment` that Warp sets for what it starts (`WARP_CLI_AGENT_PROTOCOL_VERSION`, ...). A
  /// `claude` that inherits them thinks it runs in Warp, and the Warp plugin's notifications show up as raw JSON.
  public static func otherTerminalMarkers(in environment: [String: String]) -> [String] {
    environment.keys.filter { $0.hasPrefix("WARP_") }.sorted()
  }

  /// Installs the bundle's mods into `destination` and sets `CLAUDE_CODE_PLUGIN_DIRS` in this process, so every
  /// shell it starts from now on inherits it. The mods `state` switches off are left out, and the person's own mods
  /// (`userMods`: a folder per mod, see ModFolders) are added.
  public static func export(from bundle: URL, into destination: URL, userMods: URL? = nil, state: ModState = ModState()) {
    let builtIn = install(from: bundle, into: destination)
    let own = userMods.map { ModLibrary.userMods(in: $0) } ?? []
    let all = builtIn + own
    guard let value = ModLibrary.pluginDirs(inherited: ProcessInfo.processInfo.environment[pluginDirsKey], managed: all,
                                            enabled: all.filter { state.isOn($0.lastPathComponent) }) else { return }
    setenv(pluginDirsKey, value, 1)
  }
}
