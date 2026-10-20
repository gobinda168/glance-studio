import Foundation
import Testing
@testable import GlanceCore

private func manifest(_ json: String) -> ModManifest? { ModManifest(data: Data(json.utf8)) }

@Test func aManifestGivesTheNameTheDescriptionAndAFormFromUserConfig() throws {
  let mod = try #require(manifest("""
    {"name": "glance-status", "version": "1.2.0", "description": "A pane.",
     "userConfig": {
       "refresh": {"type": "number", "title": "Refresh (s)", "default": 1, "min": 1, "max": 60},
       "mode": {"type": "string", "options": ["gist", "turbo"], "default": "gist"},
       "chip": {"type": "boolean", "description": "Show the chip", "default": true},
       "token": {"type": "string", "sensitive": true},
       "tags": {"type": "string", "multiple": true}
     }}
    """))
  #expect(mod.displayName == "Glance status")
  #expect(mod.version == "1.2.0")
  #expect(mod.detail == "A pane.")
  // Sorted by key; the list field is left out, the secret is kept (the page decides not to draw it).
  #expect(mod.fields.map(\.key) == ["chip", "mode", "refresh", "token"])
  #expect(mod.fields[0].kind == .boolean && mod.fields[0].defaultValue == .bool(true))
  #expect(mod.fields[1].options == ["gist", "turbo"] && mod.fields[1].defaultValue == .string("gist"))
  #expect(mod.fields[2].title == "Refresh (s)" && mod.fields[2].defaultValue == .number(1))
  #expect(mod.fields[3].sensitive)
}

@Test func aManifestNeedsASafeName() {
  #expect(manifest(#"{"name": "../evil"}"#) == nil)
  #expect(manifest(#"{"name": ""}"#) == nil)
  #expect(manifest(#"{"description": "no name"}"#) == nil)
  #expect(manifest("not json") == nil)
  #expect(manifest(#"{"name": "my_mod-2"}"#)?.fields.isEmpty == true)
}

@Test func aFieldOnlyTakesWhatItsTypeAllows() throws {
  let mod = try #require(manifest("""
    {"name": "m", "userConfig": {
      "n": {"type": "number", "min": 1, "max": 10},
      "pick": {"type": "string", "options": ["a", "b"]},
      "free": {"type": "string"},
      "on": {"type": "boolean"}}}
    """))
  let field = { (key: String) in mod.fields.first { $0.key == key }! }
  #expect(field("n").value(from: " 4 ") == .number(4))
  #expect(field("n").value(from: "0") == nil)
  #expect(field("n").value(from: "11") == nil)
  #expect(field("n").value(from: "many") == nil)
  #expect(field("pick").value(from: "b") == .string("b"))
  #expect(field("pick").value(from: "c") == nil)
  #expect(field("free").value(from: "anything") == .string("anything"))
  #expect(field("on").value(from: "true") == .bool(true))
  #expect(field("on").value(from: "yes") == nil)
  #expect(ModValue.number(3).text == "3" && ModValue.number(2.5).text == "2.5")
}

@Test func modsAreOnUntilTheyAreSwitchedOffAndTheChoiceIsSaved() throws {
  var state = ModState()
  #expect(state.isOn("glance-status"))
  state.set("glance-status", on: false)
  #expect(!state.isOn("glance-status") && state.isOn("glance-replies"))
  let file = FileManager.default.temporaryDirectory.appendingPathComponent("mods-\(UUID().uuidString)/mods.json")
  defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
  try state.save(to: file)
  #expect(ModState.load(from: file) == state)
  state.set("glance-status", on: true)
  #expect(state.isOn("glance-status"))
  #expect(ModState.load(from: file.deletingLastPathComponent().appendingPathComponent("missing.json")) == ModState())
}

@Test func pluginDirsKeepThePersonsOwnAndOnlyLoadTheModsThatAreOn() {
  let status = URL(fileURLWithPath: "/Caches/mods/glance-status")
  let replies = URL(fileURLWithPath: "/Caches/mods/glance-replies")
  let mine = URL(fileURLWithPath: "/Support/mods/mine")
  let managed = [status, replies, mine]
  // Launch-time value: theirs, then all the built-in mods.
  let launch = "/theirs:\(status.path):\(replies.path)"
  #expect(ModLibrary.pluginDirs(inherited: launch, managed: managed, enabled: [replies, mine])
    == "/theirs:\(replies.path):\(mine.path)")
  // A mod switched back on after launch is added again, once.
  #expect(ModLibrary.pluginDirs(inherited: launch, managed: managed, enabled: managed)
    == "/theirs:\(status.path):\(replies.path):\(mine.path)")
  #expect(ModLibrary.pluginDirs(inherited: launch, managed: managed, enabled: []) == "/theirs")
  #expect(ModLibrary.pluginDirs(inherited: status.path, managed: managed, enabled: []) == nil)
  #expect(ModLibrary.pluginDirs(inherited: nil, managed: managed, enabled: [mine]) == mine.path)
}

@Test func exportLeavesOutTheModsThatAreOff() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("mods-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: root) }
  func mod(_ name: String, in folder: URL) throws {
    let manifest = folder.appendingPathComponent("\(name)/.claude-plugin")
    try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: true)
    try Data(#"{"name": "\#(name)"}"#.utf8).write(to: manifest.appendingPathComponent("plugin.json"))
  }
  let bundle = root.appendingPathComponent("bundle")
  let user = root.appendingPathComponent("user")
  try mod("glance-status", in: bundle)
  try mod("glance-replies", in: bundle)
  try mod("mine", in: user)
  let before = ProcessInfo.processInfo.environment[ClaudeMods.pluginDirsKey]
  defer { if let before { setenv(ClaudeMods.pluginDirsKey, before, 1) } else { unsetenv(ClaudeMods.pluginDirsKey) } }
  unsetenv(ClaudeMods.pluginDirsKey)
  ClaudeMods.export(from: bundle, into: root.appendingPathComponent("copies"), userMods: user,
                    state: ModState(disabled: ["glance-status"]))
  let dirs = (ProcessInfo.processInfo.environment[ClaudeMods.pluginDirsKey] ?? "").split(separator: ":").map {
    URL(fileURLWithPath: String($0)).lastPathComponent
  }
  #expect(dirs == ["glance-replies", "mine"])
}

@Test func aSettingIsWrittenUnderPluginConfigsAndTheRestOfTheFileIsKept() throws {
  let existing = Data(#"{"theme": "dark", "pluginConfigs": {"other": {"options": {"x": 1}}}}"#.utf8)
  let written = try ModLibrary.settings(existing, setting: "refresh", of: "glance-status", to: .number(5))
  let root = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
  #expect(root["theme"] as? String == "dark")
  #expect(ModLibrary.values(for: "glance-status", in: written) == ["refresh": .number(5)])
  #expect(ModLibrary.values(for: "other", in: written) == ["x": .number(1)])

  let more = try ModLibrary.settings(written, setting: "chip", of: "glance-status", to: .bool(false))
  #expect(ModLibrary.values(for: "glance-status", in: more) == ["refresh": .number(5), "chip": .bool(false)])

  // Reset to the default removes the key, and an emptied mod leaves no stub behind.
  let reset = try ModLibrary.settings(try ModLibrary.settings(more, setting: "chip", of: "glance-status", to: nil),
                                      setting: "refresh", of: "glance-status", to: nil)
  #expect(ModLibrary.values(for: "glance-status", in: reset).isEmpty)
  let resetRoot = try #require(try JSONSerialization.jsonObject(with: reset) as? [String: Any])
  #expect((resetRoot["pluginConfigs"] as? [String: Any])?.keys.sorted() == ["other"])
}

@Test func aMissingOrEmptySettingsFileIsStartedAndAnUnreadableOneIsNeverOverwritten() throws {
  let fresh = try ModLibrary.settings(nil, setting: "a", of: "m", to: .string("x"))
  #expect(ModLibrary.values(for: "m", in: fresh) == ["a": .string("x")])
  let blank = try ModLibrary.settings(Data("  \n".utf8), setting: "a", of: "m", to: .bool(true))
  #expect(ModLibrary.values(for: "m", in: blank) == ["a": .bool(true)])
  #expect(throws: ModLibrary.SettingsError.self) {
    try ModLibrary.settings(Data("{ not json".utf8), setting: "a", of: "m", to: .bool(true))
  }
  #expect(throws: ModLibrary.SettingsError.self) {
    try ModLibrary.settings(Data("[1, 2]".utf8), setting: "a", of: "m", to: .bool(true))
  }
}

@Test func aBooleanIsNotReadBackAsANumber() throws {
  let data = Data(#"{"pluginConfigs": {"m": {"options": {"on": true, "one": 1, "name": "x", "list": [1]}}}}"#.utf8)
  #expect(ModLibrary.values(for: "m", in: data) == ["on": .bool(true), "one": .number(1), "name": .string("x")])
}
