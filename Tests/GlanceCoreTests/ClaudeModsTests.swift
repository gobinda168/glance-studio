import Foundation
import Testing
@testable import GlanceCore

@Test func findsTheModDirectoriesWithAManifest() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("mods-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: root) }
  for name in ["zeta", "alpha"] {
    let manifest = root.appendingPathComponent("\(name)/.claude-plugin")
    try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: manifest.appendingPathComponent("plugin.json"))
  }
  try FileManager.default.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
  #expect(ClaudeMods.bundled(in: root).map(\.lastPathComponent) == ["alpha", "zeta"])
  #expect(ClaudeMods.bundled(in: root.appendingPathComponent("missing")).isEmpty)
}

@Test func addsTheModsAfterThePersonsOwnPluginDirs() {
  let mods = [URL(fileURLWithPath: "/App/Resources/mods/glance-replies")]
  #expect(ClaudeMods.pluginDirs(adding: mods, to: nil) == "/App/Resources/mods/glance-replies")
  #expect(ClaudeMods.pluginDirs(adding: mods, to: "/mine") == "/mine:/App/Resources/mods/glance-replies")
  // Exported once already (a relaunch from a Studio shell): not added twice.
  #expect(ClaudeMods.pluginDirs(adding: mods, to: "/App/Resources/mods/glance-replies") == "/App/Resources/mods/glance-replies")
  #expect(ClaudeMods.pluginDirs(adding: [], to: "") == nil)
}

@Test func installsAFreshCopyOfEachMod() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("mods-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: root) }
  let bundle = root.appendingPathComponent("Resources/mods")
  let manifest = bundle.appendingPathComponent("glance-replies/.claude-plugin")
  try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: true)
  try Data("{}".utf8).write(to: manifest.appendingPathComponent("plugin.json"))
  try Data("v2".utf8).write(to: bundle.appendingPathComponent("glance-replies/register.js"))
  // Last launch's copy, with the types Claude Code wrote into it and a mod since removed from the app.
  let destination = root.appendingPathComponent("Caches/Glance Studio/mods")
  try FileManager.default.createDirectory(at: destination.appendingPathComponent("old-mod"), withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: destination.appendingPathComponent("glance-replies/.claude-plugin/types"), withIntermediateDirectories: true)

  let mods = ClaudeMods.install(from: bundle, into: destination)

  #expect(mods.map(\.path) == [destination.appendingPathComponent("glance-replies").path])
  #expect(try String(contentsOf: destination.appendingPathComponent("glance-replies/register.js"), encoding: .utf8) == "v2")
  #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("old-mod").path))
  #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("glance-replies/.claude-plugin/types").path))
}

@Test func sessionMarkersAreTheClaudeVariablesButThePluginDirs() {
  let env = [
    "CLAUDECODE": "1", "CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDE_CODE_SESSION_ID": "abc", "CLAUDE_PID": "42",
    "CLAUDE_CODE_PLUGIN_DIRS": "/mods", "PATH": "/usr/bin", "HOME": "/Users/me",
  ]
  #expect(ClaudeMods.sessionMarkers(in: env) == ["CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID", "CLAUDE_PID"])
}

@Test func warpsVariablesAreAnotherTerminalsMarkers() {
  let env = [
    "WARP_CLI_AGENT_PROTOCOL_VERSION": "1", "WARP_CLIENT_VERSION": "v0.2026.09.30.08.29.stable_01",
    "WARP_IS_LOCAL_SHELL_SESSION": "1", "TERM_PROGRAM": "ghostty", "PATH": "/usr/bin", "WARPED": "x",
  ]
  #expect(ClaudeMods.otherTerminalMarkers(in: env)
    == ["WARP_CLIENT_VERSION", "WARP_CLI_AGENT_PROTOCOL_VERSION", "WARP_IS_LOCAL_SHELL_SESSION"])
}
