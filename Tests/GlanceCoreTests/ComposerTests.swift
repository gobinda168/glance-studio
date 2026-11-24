import Foundation
import Testing
@testable import GlanceCore

@Test func slashTriggerOnlyAtStart() {
  #expect(ComposerTrigger.at("/mo", caret: 3) == .slash(query: "mo"))
  #expect(ComposerTrigger.at("/model x", caret: 8) == nil)
  #expect(ComposerTrigger.at("hi /mo", caret: 6) == nil)
}

@Test func mentionTriggerAfterSpace() {
  #expect(ComposerTrigger.at("look at @src/a", caret: 14) == .mention(query: "src/a", start: 8))
  #expect(ComposerTrigger.at("mail@x", caret: 6) == nil)
  let r = ComposerTrigger.replaceMention(in: "look at @src/a now", start: 8, caret: 14, with: "src/auth.ts")
  #expect(r.text == "look at @src/auth.ts  now")
  #expect(r.caret == 21)
}

@Test func frontmatterReadsNameAndDescription() {
  let fm = SlashCatalog.frontmatter("---\nname: ship\ndescription: \"Ship it: build, test, PR\"\n---\nBody")
  #expect(fm["name"] == "ship")
  #expect(fm["description"] == "Ship it: build, test, PR")
}

@Test func frontmatterHandlesCRLF() {
  let fm = SlashCatalog.frontmatter("---\r\nname: test\r\ndescription: \"Works\"\r\n---\r\nBody")
  #expect(fm["name"] == "test")
  #expect(fm["description"] == "Works")
}

@Test func frontmatterHandlesBlockScalars() {
  let text = "---\nname: cmd\ndescription: >\n  Multi-line\n  description here\n---\nBody"
  let fm = SlashCatalog.frontmatter(text)
  #expect(fm["name"] == "cmd")
  #expect(fm["description"] == "Multi-line description here")
}

@Test func scanFindsUserProjectAndPluginCommands() throws {
  let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
  let project = home + "/proj"
  let files = [
    "\(home)/.claude/commands/standup.md": "---\ndescription: Daily standup\n---\n",
    "\(project)/.claude/commands/ship.md": "Ship it\n",
    "\(home)/.claude/skills/notes/SKILL.md": "---\nname: notes\ndescription: Take notes\n---\n",
    "\(home)/.claude/plugins/cache/mkt/glance/1.0.0/skills/glance-proof/SKILL.md": "---\nname: glance-proof\ndescription: Prove work\n---\n",
  ]
  for (path, body) in files {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try body.write(toFile: path, atomically: true, encoding: .utf8)
  }
  defer { try? FileManager.default.removeItem(atPath: home) }
  let found = SlashCatalog.scan(home: home, project: project)
  #expect(found.contains(SlashCommand(name: "standup", summary: "Daily standup", source: .user)))
  #expect(found.contains(SlashCommand(name: "ship", summary: "Ship it", source: .project)))
  #expect(found.contains(SlashCommand(name: "notes", summary: "Take notes", source: .user)))
  #expect(found.contains(SlashCommand(name: "glance:glance-proof", summary: "Prove work", source: .plugin("glance"))))
}

@Test func scanReadsInstalledPluginsJson() throws {
  let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
  let pluginPath = home + "/plugins/cache/superpowers/6.4.1"
  let files = [
    "\(pluginPath)/skills/brainstorming/SKILL.md": "---\nname: brainstorming\ndescription: Brainstorm ideas\n---\n",
    "\(home)/.claude/plugins/installed_plugins.json": """
    {"version": 2, "plugins": {"superpowers@claude-plugins-official": [{"scope":"user","installPath":"\(pluginPath)","version":"6.4.1","installedAt":"2026-10-01T00:00:00Z","lastUpdated":"2026-10-20T14:21:16.077Z"}]}}
    """,
  ]
  for (path, body) in files {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try body.write(toFile: path, atomically: true, encoding: .utf8)
  }
  defer { try? FileManager.default.removeItem(atPath: home) }
  let found = SlashCatalog.scan(home: home, project: nil)
  #expect(found.contains(SlashCommand(name: "superpowers:brainstorming", summary: "Brainstorm ideas", source: .plugin("superpowers"))))
}

@Test func scanSkipsDisabledPlugins() throws {
  let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
  let pluginPath = home + "/plugins/cache/superpowers/6.4.1"
  let files = [
    "\(pluginPath)/skills/brainstorming/SKILL.md": "---\ndescription: Brainstorm ideas\n---\n",
    "\(home)/.claude/plugins/installed_plugins.json": """
    {"version": 2, "plugins": {"superpowers@claude-plugins-official": [{"scope":"user","installPath":"\(pluginPath)","version":"6.4.1","installedAt":"2026-10-01T00:00:00Z","lastUpdated":"2026-10-20T14:21:16.077Z"}]}}
    """,
    "\(home)/.claude/settings.json": """
    {"enabledPlugins": {"superpowers@claude-plugins-official": false}}
    """,
  ]
  for (path, body) in files {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try body.write(toFile: path, atomically: true, encoding: .utf8)
  }
  defer { try? FileManager.default.removeItem(atPath: home) }
  let found = SlashCatalog.scan(home: home, project: nil)
  #expect(!found.contains { $0.source == .plugin("superpowers") })
}

@Test func fallbackPicksNewestVersion() throws {
  let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
  let files = [
    "\(home)/.claude/plugins/cache/market/plugin/1.9.0/skills/tool/SKILL.md": "---\ndescription: Old\n---\n",
    "\(home)/.claude/plugins/cache/market/plugin/1.10.0/skills/tool/SKILL.md": "---\ndescription: New\n---\n",
  ]
  for (path, body) in files {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try body.write(toFile: path, atomically: true, encoding: .utf8)
  }
  defer { try? FileManager.default.removeItem(atPath: home) }
  let found = SlashCatalog.scan(home: home, project: nil)
  let cmd = found.first { $0.name.contains("tool") }
  #expect(cmd?.summary == "New")
}

@Test func installedPluginsJsonPreventsFallback() throws {
  let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
  let pluginPath = home + "/plugins/cache/superpowers/6.4.1"
  let cachePluginPath = home + "/.claude/plugins/cache/market/other/1.0.0"
  let files = [
    "\(pluginPath)/skills/brainstorming/SKILL.md": "---\ndescription: Brainstorm ideas\n---\n",
    "\(cachePluginPath)/skills/tool/SKILL.md": "---\ndescription: Cache tool\n---\n",
    "\(home)/.claude/plugins/installed_plugins.json": """
    {"version": 2, "plugins": {"superpowers@claude-plugins-official": [{"scope":"user","installPath":"\(pluginPath)","version":"6.4.1","installedAt":"2026-10-01T00:00:00Z","lastUpdated":"2026-10-20T14:21:16.077Z"}]}}
    """,
    "\(home)/.claude/settings.json": """
    {"enabledPlugins": {"superpowers@claude-plugins-official": false}}
    """,
  ]
  for (path, body) in files {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try body.write(toFile: path, atomically: true, encoding: .utf8)
  }
  defer { try? FileManager.default.removeItem(atPath: home) }
  let found = SlashCatalog.scan(home: home, project: nil)
  #expect(!found.contains { $0.name.contains("tool") })
  #expect(!found.contains { $0.source == .plugin("superpowers") })
  #expect(!found.contains { $0.source == .plugin("other") })
}

@Test func fallbackIgnoresStrayFilesAndTempDirs() throws {
  let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
  let files = [
    "\(home)/.claude/plugins/cache/mkt/glance/1.0.0/skills/glance-proof/SKILL.md": "---\nname: glance-proof\ndescription: Prove work\n---\n",
    "\(home)/.claude/plugins/cache/mkt/glance/temp_123/skills/old/SKILL.md": "---\ndescription: Old version\n---\n",
  ]
  for (path, body) in files {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try body.write(toFile: path, atomically: true, encoding: .utf8)
  }
  let pluginPath = home + "/.claude/plugins/cache/mkt/glance"
  try FileManager.default.createFile(atPath: pluginPath + "/zzz", contents: Data())
  defer { try? FileManager.default.removeItem(atPath: home) }
  let found = SlashCatalog.scan(home: home, project: nil)
  #expect(found.contains { $0.name == "glance:glance-proof" })
  #expect(!found.contains { $0.name.contains("old") })
}

@Test func blockScalarStopsAtIndentZero() throws {
  let text = "---\ndescription: >\n  Multi line\n  text\nname: foo\n---"
  let fm = SlashCatalog.frontmatter(text)
  #expect(fm["description"] == "Multi line text")
  #expect(fm["name"] == "foo")
}

@Test func blockScalarWithCRLF() throws {
  let text = "---\r\ndescription: >\r\n  Multi line\r\n  text\r\nname: foo\r\n---"
  let fm = SlashCatalog.frontmatter(text)
  #expect(fm["description"] == "Multi line text")
  #expect(fm["name"] == "foo")
}

@Test func matchesPrefixFirst() {
  let cmds = [SlashCommand(name: "review", summary: "", source: .builtIn), SlashCommand(name: "model", summary: "Pick a model", source: .builtIn),
              SlashCommand(name: "pr-comments", summary: "review comments", source: .builtIn)]
  #expect(SlashCatalog.matches("re", in: cmds).map(\.name) == ["review", "pr-comments"])
  #expect(SlashCatalog.isInteractive("model"))
  #expect(!SlashCatalog.isInteractive("compact"))
}

@Test func fileRankPrefersBasename() {
  let paths = ["docs/auth-notes.md", "src/auth.ts", "src/oauth/client.ts", "README.md"]
  #expect(FileMention.rank("auth", in: paths) == ["src/auth.ts", "docs/auth-notes.md", "src/oauth/client.ts"])
}
