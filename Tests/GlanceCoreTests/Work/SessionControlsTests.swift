import Foundation
import Testing
@testable import GlanceCore

// Footers as Claude Code 2.1.292 drew them.
private let autoFooter = "❯ \n─────\n  ⏵⏵ auto mode on (shift+tab to cycle) · ← 2 agents        ◐ medium · /effort\n  ○ Status · $0.00\n"

@Suite struct SessionControlsTests {
  @Test func theFooterSaysTheModeAndEffort() {
    #expect(SessionFooter.parse(screen: autoFooter) == SessionFooter(mode: .auto, effort: "medium"))
    #expect(SessionFooter.parse(screen: "  ⏸ manual mode on\n")?.mode == .manual)
    #expect(SessionFooter.parse(screen: "  ⏵⏵ accept edits on (shift+tab to cycle)      ● high · /effort\n")
      == SessionFooter(mode: .acceptEdits, effort: "high"))
    #expect(SessionFooter.parse(screen: "  ⏸ plan mode on (shift+tab to cycle)      ○ low · /effort")?.mode == .plan)
    #expect(SessionFooter.parse(screen: "  ⏵⏵ bypass permissions on (shift+tab to cycle)")?.mode == .bypass)
  }

  @Test func aModelWithoutAutoSaysSo() {
    let footer = SessionFooter.parse(screen: "  ⏸ manual mode on · ← 2 agents    auto mode unavailable for this model\n")
    #expect(footer == SessionFooter(mode: .manual, effort: nil, autoUnavailable: true))
  }

  @Test func chatTextIsNotAFooter() {
    #expect(SessionFooter.parse(screen: "Claude said auto mode on is the default.\nplan mode on means no edits\n") == nil)
    #expect(SessionFooter.parse(screen: "") == nil)
    // Far above the bottom of the screen, it's scrollback someone is reading.
    let old = "  ⏸ plan mode on\n" + String(repeating: "line\n", count: 20)
    #expect(SessionFooter.parse(screen: old) == nil)
  }

  @Test func theLastFooterOnScreenCounts() {
    #expect(SessionFooter.parse(screen: "  ⏸ plan mode on\n  ⏵⏵ auto mode on\n")?.mode == .auto)
  }

  @Test func switchingPressesUntilTheModeShows() {
    #expect(ModeSwitch.next(target: .plan, start: .auto, seen: .auto, presses: 0) == .press)
    #expect(ModeSwitch.next(target: .plan, start: .auto, seen: .manual, presses: 1) == .press)
    #expect(ModeSwitch.next(target: .plan, start: .auto, seen: .plan, presses: 3) == .done)
    #expect(ModeSwitch.next(target: .auto, start: .auto, seen: .auto, presses: 0) == .done)
  }

  @Test func aModeThatIsNotInTheCycleFailsBackWhereItStarted() {
    // A full circle: pressing on would leave Claude in some other mode, possibly bypass.
    #expect(ModeSwitch.next(target: .auto, start: .manual, seen: .manual, presses: 3) == .failed)
    #expect(ModeSwitch.next(target: .auto, start: .manual, seen: .bypass, presses: ModeSwitch.maxPresses) == .failed)
  }

  @Test func noFooterMeansItCannotBeConfirmed() {
    #expect(ModeSwitch.next(target: .plan, start: .auto, seen: nil, presses: 1) == .failed)
    #expect(ModeSwitch.next(target: .plan, start: nil, seen: nil, presses: 0) == .failed)
  }

  @Test func theMenuLeavesBypassOut() {
    #expect(PermissionMode.menu == [.manual, .acceptEdits, .plan, .auto])
    #expect(PermissionMode.auto.chip == "Auto mode")
    #expect(PermissionMode.plan.chip == "Plan mode")
    #expect(PermissionMode.acceptEdits.chip == "Accept edits")
  }

  @Test func transcriptNamesForModes() {
    #expect(PermissionMode(transcript: "auto") == .auto)
    #expect(PermissionMode(transcript: "default") == .manual)
    #expect(PermissionMode(transcript: "manual") == .manual)
    #expect(PermissionMode(transcript: "acceptEdits") == .acceptEdits)
    #expect(PermissionMode(transcript: "plan") == .plan)
    #expect(PermissionMode(transcript: "bypassPermissions") == .bypass)
    #expect(PermissionMode(transcript: "somethingNew") == nil)
  }

  @Test func thePickedModelIsMatchedByFamilyWhateverTheVersion() {
    #expect(SessionPicks.family(of: "claude-opus-5-5") == "opus")
    #expect(SessionPicks.family(of: "Sonnet 5.5") == "sonnet")
    #expect(SessionPicks.family(of: "claude-haiku-4-5-20251001") == "haiku")
    #expect(SessionPicks.family(of: "something-else") == nil)
    #expect(SessionPicks.models.map(\.command) == ["/model opus", "/model sonnet", "/model haiku", "/model fable"])
    #expect(SessionPicks.efforts.map(\.level) == ["auto", "low", "medium", "high", "xhigh", "max"])
  }

  @Test func aQueuedCommandLeavesTheQueueWhenItsRowLands() {
    let command = TimelineRow.Kind.command(name: "/model", output: nil)
    #expect(command.takes(queued: "/model sonnet"))
    #expect(!command.takes(queued: "/effort high"))
    #expect(!command.takes(queued: "model sonnet"))
    let user = TimelineRow.Kind.user(text: " fix it ", images: [])
    #expect(user.takes(queued: "fix it"))
    #expect(!user.takes(queued: "/model sonnet"))
  }
}

private func settings(_ lines: [String]) -> SessionSettings {
  var t = SessionTimeline(root: nil)
  t.ingest(lines: lines)
  return t.settings
}

private func commandLines(_ name: String, _ args: String, output: String) -> [String] {
  [#"{"type":"user","uuid":"c1","message":{"role":"user","content":"<command-name>/\#(name)</command-name>\n<command-message>\#(name)</command-message>\n<command-args>\#(args)</command-args>"}}"#,
   #"{"type":"user","uuid":"c2","message":{"role":"user","content":"<local-command-stdout>\#(output)</local-command-stdout>"}}"#]
}

private let reply = #"{"type":"assistant","uuid":"a1","effort":"high","message":{"id":"m1","role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"Hi."}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}}"#

@Suite struct SessionSettingsTests {
  @Test func aReplySaysItsModelAndEffort() {
    #expect(settings([reply]) == SessionSettings(model: "claude-opus-5-5", effort: "high"))
  }

  @Test func aPickBeforeTheFirstMessageCounts() {
    let s = settings(commandLines("model", "sonnet", output: "Set model to `Sonnet 5.5` and saved as your default for new sessions")
      + commandLines("effort", "low", output: "Set effort level to low (saved as your default for new sessions): Quick"))
    #expect(s == SessionSettings(model: "Sonnet 5.5", effort: "low"))
  }

  @Test func theLatestWins() {
    #expect(settings([reply] + commandLines("model", "haiku", output: "Set model to `Haiku 4.5` and saved")).model == "Haiku 4.5")
    #expect(settings(commandLines("model", "haiku", output: "Set model to `Haiku 4.5` and saved") + [reply]).model == "claude-opus-5-5")
  }

  @Test func aSubagentsModelIsNotTheSessions() {
    let side = #"{"type":"assistant","uuid":"a2","isSidechain":true,"effort":"low","message":{"id":"m2","role":"assistant","model":"claude-haiku-4-5","content":[],"usage":{"input_tokens":1,"output_tokens":1}}}"#
    #expect(settings([reply, side]) == SessionSettings(model: "claude-opus-5-5", effort: "high"))
  }

  @Test func otherCommandsOutputChangesNothing() {
    #expect(settings([reply] + commandLines("status", "", output: "Set model to `Nope` and saved")).model == "claude-opus-5-5")
    #expect(settings([reply] + commandLines("model", "", output: "Kept model as Opus")).model == "claude-opus-5-5")
  }

  @Test func theModeEntryIsRead() {
    #expect(settings([#"{"type":"permission-mode","permissionMode":"plan","sessionId":"s"}"#]).permissionMode == .plan)
    #expect(settings([#"{"type":"permission-mode","permissionMode":"plan"}"#, #"{"type":"permission-mode","permissionMode":"somethingNew"}"#]).permissionMode == .plan)
  }
}
