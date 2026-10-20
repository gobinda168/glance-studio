import AppKit
import Combine
import GlanceCore

/// The mod library: the mods Glance ships and the ones the person added (`~/Library/Application Support/Glance/mods`),
/// which of them are on, and the values of their settings (`userConfig`, kept in Claude Code's settings.json).
///
/// Every `claude` a new terminal tab starts loads the mods that are on (`pluginDirs`, called from
/// StudioClaudeFolders.environment): switching one reaches the tabs opened after it.
@MainActor
public final class ModStore: ObservableObject {
  public static let shared = ModStore()

  public struct Entry: Identifiable, Equatable {
    public var id: String { manifest.name }
    public let manifest: ModManifest
    public let folder: URL
    public let isBuiltIn: Bool
  }

  @Published public private(set) var mods: [Entry] = []
  @Published public private(set) var state = ModState.load()
  /// `pluginConfigs[mod].options` from Claude Code's settings, by mod.
  @Published public private(set) var values: [String: [String: ModValue]] = [:]
  /// The last thing that went wrong, shown on the page until the next action.
  @Published public private(set) var problem: String?

  private init() { reload() }

  public var userMods: [Entry] { mods.filter { !$0.isBuiltIn } }
  public var builtInMods: [Entry] { mods.filter(\.isBuiltIn) }

  public func isOn(_ name: String) -> Bool { state.isOn(name) }

  public func entry(named name: String?) -> Entry? { name.flatMap { name in mods.first { $0.id == name } } }

  /// Reads the folders and Claude Code's settings again.
  public func reload() {
    let builtIn = Self.entries(in: ModFolders.builtInCopies, builtIn: true)
    let own = Self.entries(in: ModFolders.userMods, builtIn: false).filter { mine in
      !builtIn.contains { $0.id == mine.id }
    }
    mods = (builtIn + own).sorted { $0.manifest.displayName.localizedCaseInsensitiveCompare($1.manifest.displayName) == .orderedAscending }
    state = ModState.load()
    let settings = try? Data(contentsOf: ModFolders.claudeSettings)
    values = Dictionary(uniqueKeysWithValues: mods.map { ($0.id, ModLibrary.values(for: $0.id, in: settings)) })
  }

  private static func entries(in folder: URL, builtIn: Bool) -> [Entry] {
    ClaudeMods.bundled(in: folder).compactMap { url in
      guard let data = try? Data(contentsOf: url.appendingPathComponent(".claude-plugin/plugin.json")),
            let manifest = ModManifest(data: data) else { return nil }
      return Entry(manifest: manifest, folder: url, isBuiltIn: builtIn)
    }
  }

  // MARK: On and off

  public func setOn(_ name: String, _ on: Bool) {
    problem = nil
    var next = state
    next.set(name, on: on)
    do {
      try next.save()
      state = next
    } catch {
      problem = "Couldn't save that: \(error.localizedDescription)"
    }
  }

  // MARK: Settings

  /// The value shown for a field: what's stored, else the mod's default.
  public func value(of field: ModManifest.Field, in mod: String) -> ModValue? {
    values[mod]?[field.key] ?? field.defaultValue
  }

  /// Stores `value` for the field (nil: back to the default).
  public func set(_ field: ModManifest.Field, in mod: String, to value: ModValue?) {
    problem = nil
    let url = ModFolders.claudeSettings
    do {
      let data = try ModLibrary.settings(try? Data(contentsOf: url), setting: field.key, of: mod, to: value)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
      values[mod, default: [:]][field.key] = value
    } catch let error as ModLibrary.SettingsError {
      problem = error.message
    } catch {
      problem = "Couldn't save that: \(error.localizedDescription)"
    }
  }

  // MARK: Adding and removing

  /// Copies the mod in `source` (a folder holding `.claude-plugin/plugin.json`) into the library. Returns its name.
  @discardableResult
  public func add(from source: URL) -> String? {
    problem = nil
    let fm = FileManager.default
    guard let data = try? Data(contentsOf: source.appendingPathComponent(".claude-plugin/plugin.json")),
          let manifest = ModManifest(data: data) else {
      problem = "That folder isn't a Claude Code mod: it needs a .claude-plugin/plugin.json with a name."
      return nil
    }
    if builtInMods.contains(where: { $0.id == manifest.name }) {
      problem = "\(manifest.name) is one of Glance's own mods. Rename yours in its plugin.json."
      return nil
    }
    let destination = ModFolders.userMods.appendingPathComponent(manifest.name, isDirectory: true)
    if source.standardizedFileURL.path == destination.standardizedFileURL.path { reload(); return manifest.name }
    do {
      try fm.createDirectory(at: ModFolders.userMods, withIntermediateDirectories: true)
      // A mod added again is replaced, so the library always holds the copy that was picked last.
      let staged = ModFolders.userMods.appendingPathComponent(".adding-\(UUID().uuidString)")
      try fm.copyItem(at: source, to: staged)
      for leftover in [".git", "node_modules", ".claude-plugin/types"] {
        try? fm.removeItem(at: staged.appendingPathComponent(leftover))
      }
      try? fm.removeItem(at: destination)
      try fm.moveItem(at: staged, to: destination)
    } catch {
      problem = "Couldn't add it: \(error.localizedDescription)"
      return nil
    }
    reload()
    return manifest.name
  }

  /// Removes a mod the person added (a built-in one can only be switched off). Its settings stay in Claude Code's file.
  public func remove(_ name: String) {
    problem = nil
    guard let entry = entry(named: name), !entry.isBuiltIn else { return }
    do {
      try FileManager.default.trashItem(at: entry.folder, resultingItemURL: nil)
      var next = state
      next.set(name, on: true)
      try? next.save()
    } catch {
      problem = "Couldn't remove it: \(error.localizedDescription)"
    }
    reload()
  }

  // MARK: Terminals

  /// `CLAUDE_CODE_PLUGIN_DIRS` for a new terminal: `inherited` without Glance's mods, then the ones that are on. Read
  /// from disk each time, so a switch reaches the next tab.
  public nonisolated static func pluginDirs(inherited: String?) -> String? {
    let state = ModState.load()
    let all = ClaudeMods.bundled(in: ModFolders.builtInCopies) + ModLibrary.userMods()
    return ModLibrary.pluginDirs(inherited: inherited, managed: all, enabled: all.filter { state.isOn($0.lastPathComponent) })
  }
}
