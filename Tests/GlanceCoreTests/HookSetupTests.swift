import Foundation
import Testing
@testable import GlanceCore

private let command = "'/Users/me/.claude/glance/notify.sh' # glance"

private func hooks(_ settings: [String: Any], _ event: String) -> [[String: Any]] {
  ((settings["hooks"] as? [String: Any])?[event] as? [[String: Any]]) ?? []
}

@Test func installAddsBothEventsAndKeepsEverythingElse() {
  let existing: [String: Any] = [
    "model": "opus",
    "hooks": ["Stop": [["matcher": "", "hooks": [["type": "command", "command": "afplay done.aiff"]]]]],
  ]
  let out = HookSetup.install(into: existing, command: command)
  #expect(out["model"] as? String == "opus")
  #expect(hooks(out, "Stop").count == 2)
  #expect(hooks(out, "UserPromptSubmit").count == 1)
  let ours = hooks(out, "Stop")[1]["hooks"] as? [[String: Any]]
  #expect(ours?.first?["command"] as? String == command)
}

@Test func installIsIdempotent() {
  let once = HookSetup.install(into: [:], command: command)
  let twice = HookSetup.install(into: once, command: command)
  #expect(hooks(twice, "Stop").count == 1)
  #expect(hooks(twice, "UserPromptSubmit").count == 1)
}

@Test func uninstallRemovesOnlyGlanceAndEmptyContainers() {
  let foreign: [String: Any] = ["hooks": [["type": "command", "command": "afplay done.aiff"]]]
  let installed = HookSetup.install(into: ["hooks": ["Stop": [foreign]]], command: command)
  let out = HookSetup.uninstall(from: installed)
  #expect(hooks(out, "Stop").count == 1)
  #expect((out["hooks"] as? [String: Any])?["UserPromptSubmit"] == nil)
  #expect(HookSetup.uninstall(from: HookSetup.install(into: [:], command: command))["hooks"] == nil)
}

@Test func isInstalledNeedsGlanceOnEveryEvent() {
  #expect(!HookSetup.isInstalled(in: [:]))
  let installed = HookSetup.install(into: [:], command: command)
  #expect(HookSetup.isInstalled(in: installed))
  var half = installed
  var hooksOnly = half["hooks"] as? [String: Any] ?? [:]
  hooksOnly["Stop"] = [["hooks": [["type": "command", "command": "afplay done.aiff"]]]]
  half["hooks"] = hooksOnly
  #expect(!HookSetup.isInstalled(in: half))
  #expect(!HookSetup.isInstalled(in: HookSetup.uninstall(from: installed)))
}
