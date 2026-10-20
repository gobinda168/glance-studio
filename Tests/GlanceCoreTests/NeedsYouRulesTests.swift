import Foundation
import Testing
@testable import GlanceCore

private let dialog = DialogScreen(question: "Do you want to proceed?", detail: ["Task", "Read the repo"],
                                  options: [PromptOption(number: 1, label: "Yes", note: nil, checked: nil),
                                            PromptOption(number: 2, label: "No", note: nil, checked: nil)],
                                  selected: 0)
private func prompt(_ name: String, _ input: [String: JSONValue]) -> PendingPrompt {
  PendingPrompt(surface: "S", cwd: "/Users/me/app", call: ToolCall(id: "t", name: name, input: .object(input)),
                screen: dialog, created: Date(timeIntervalSince1970: 0))
}

@Test func autoOpenFollowsTheSettingUnlessTheSplitIsFocused() {
  #expect(NeedsYouRules.open(setting: .glow, splitFocused: false) == .none)
  #expect(NeedsYouRules.open(setting: .card, splitFocused: false) == .card)
  #expect(NeedsYouRules.open(setting: .cardAndKeyboard, splitFocused: false) == .cardAndKeyboard)
  #expect(NeedsYouRules.open(setting: .cardAndKeyboard, splitFocused: true) == .none)
  #expect(NeedsYouOpen(rawValue: "nonsense") == nil)
}

@Test func theCaptionNamesTheProjectAndWhatsAsked() {
  #expect(NeedsYouRules.caption(prompt("Bash", ["command": .string("ls")])) == "app needs you: Bash command")
  #expect(NeedsYouRules.caption(prompt("AskUserQuestion", [:])) == "app needs you: a question")
  #expect(NeedsYouRules.caption(prompt("ExitPlanMode", [:])) == "app needs you: plan approval")
  #expect(NeedsYouRules.caption(prompt("WebFetch", [:])) == "app needs you: WebFetch")
}

@Test func detailsPerTool() {
  #expect(PromptDetails.of(prompt("Bash", ["command": .string("rm -rf build")])) == .command("rm -rf build"))
  #expect(PromptDetails.of(prompt("Edit", ["file_path": .string("/a/x.swift"), "old_string": .string("a\nb"),
                                           "new_string": .string("c")]))
    == .edit(path: "/a/x.swift", added: 1, removed: 2))
  #expect(PromptDetails.of(prompt("Write", ["file_path": .string("/a/y"), "content": .string("1\n2\n3")]))
    == .edit(path: "/a/y", added: 3, removed: 0))
  #expect(PromptDetails.of(prompt("WebFetch", ["url": .string("https://x.dev"), "prompt": .string("…")]))
    == .fields(["url: https://x.dev"]))
  #expect(PromptDetails.of(prompt("ExitPlanMode", ["plan": .string("# Plan\n1. a")])) == .plan("# Plan\n1. a"))
  #expect(PromptDetails.of(prompt("AskUserQuestion", [:])) == .none)
}

@Test func subagentPromptShowsTheScreenLines() {
  #expect(PromptDetails.of(prompt("Agent", ["prompt": .string("go")])) == .screen(["Task", "Read the repo"]))
  #expect(PromptDetails.of(prompt("Task", [:])) == .screen(["Task", "Read the repo"]))
}

@Test func aPromptOutranksMeetingsButNotListening() {
  #expect(OrbModes.pick(panel: "idle", channel: nil, attention: true, prompt: true) == "waiting")
  #expect(OrbModes.pick(panel: "idle", channel: "listening", attention: false, prompt: true) == "listening")
  #expect(OrbModes.pick(panel: "idle", channel: "working", attention: true, prompt: false) == "meeting")
  #expect(OrbModes.pick(panel: "thinking", channel: nil, attention: false, prompt: false) == "thinking")
}
