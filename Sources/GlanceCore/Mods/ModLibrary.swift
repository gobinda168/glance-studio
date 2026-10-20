import Foundation

/// Where mods live, on disk. Everything of the person's is under one `mods` folder, in Glance's Application Support.
public enum ModFolders {
  /// `~/Library/Application Support/Glance/mods`: a folder per mod the person added, and `mods.json` (which are off).
  public static var userMods: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Glance/mods", isDirectory: true)
  }

  /// The copy of the mods the app ships, made at every launch (ClaudeMods.install).
  public static var builtInCopies: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Glance Studio/mods", isDirectory: true)
  }

  public static var stateFile: URL { userMods.appendingPathComponent("mods.json") }

  /// Claude Code's own settings, where a mod's `userConfig` values are kept.
  public static var claudeSettings: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
  }
}

/// Which mods are switched off. Everything is on until the person turns it off.
public struct ModState: Codable, Equatable, Sendable {
  public private(set) var disabled: Set<String>

  public init(disabled: Set<String> = []) { self.disabled = disabled }

  public func isOn(_ name: String) -> Bool { !disabled.contains(name) }

  public mutating func set(_ name: String, on: Bool) {
    if on { disabled.remove(name) } else { disabled.insert(name) }
  }

  /// The saved state; nothing off when the file is missing or unreadable.
  public static func load(from url: URL = ModFolders.stateFile) -> ModState {
    (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ModState.self, from: $0) } ?? ModState()
  }

  public func save(to url: URL = ModFolders.stateFile) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(self).write(to: url, options: .atomic)
  }
}

/// How the mods become `CLAUDE_CODE_PLUGIN_DIRS`, and how their settings reach Claude Code.
public enum ModLibrary {
  /// `inherited` with every mod Glance manages (`managed`: the built-in copies and the person's) taken out, then the
  /// enabled ones added after what the person set themselves. Nil when nothing is left.
  public static func pluginDirs(inherited: String?, managed: [URL], enabled: [URL]) -> String? {
    let owned = Set(managed.map(\.path))
    let kept = (inherited ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty && !owned.contains($0) }
    return ClaudeMods.pluginDirs(adding: enabled, to: kept.isEmpty ? nil : kept.joined(separator: ":"))
  }

  /// The mod folders of the person, in `folder`.
  public static func userMods(in folder: URL = ModFolders.userMods) -> [URL] { ClaudeMods.bundled(in: folder) }

  // MARK: Settings

  public struct SettingsError: Error, Equatable, Sendable {
    public let message: String
  }

  /// The values stored for `mod` under `pluginConfigs[mod].options` in the settings JSON.
  public static func values(for mod: String, in settings: Data?) -> [String: ModValue] {
    guard let settings, let root = (try? JSONSerialization.jsonObject(with: settings)) as? [String: Any],
          let options = ((root["pluginConfigs"] as? [String: Any])?[mod] as? [String: Any])?["options"] as? [String: Any]
    else { return [:] }
    return options.compactMapValues(ModValue.init(json:))
  }

  /// `settings` with `mod`'s `key` set to `value` (nil: removed, so the default applies again). Everything else in the
  /// file is kept. Throws when the file is not a JSON object, so a hand-edited file is never overwritten.
  public static func settings(_ settings: Data?, setting key: String, of mod: String, to value: ModValue?) throws -> Data {
    var root: [String: Any] = [:]
    if let settings, !settings.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
      guard let parsed = (try? JSONSerialization.jsonObject(with: settings)) as? [String: Any] else {
        throw SettingsError(message: "Claude Code's settings.json isn't a JSON object, so it was left alone.")
      }
      root = parsed
    }
    var configs = (root["pluginConfigs"] as? [String: Any]) ?? [:]
    var entry = (configs[mod] as? [String: Any]) ?? [:]
    var options = (entry["options"] as? [String: Any]) ?? [:]
    options[key] = value?.json
    if options.isEmpty { entry["options"] = nil } else { entry["options"] = options }
    configs[mod] = entry.isEmpty ? nil : entry
    root["pluginConfigs"] = configs.isEmpty ? nil : configs
    return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
  }
}
