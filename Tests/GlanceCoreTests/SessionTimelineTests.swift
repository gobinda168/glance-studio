import Foundation
import Testing
@testable import GlanceCore

private func timeline(_ lines: [String], root: String? = "/p") -> SessionTimeline {
  var t = SessionTimeline(root: root)
  t.ingest(lines: lines)
  return t
}

private let prompt = #"{"type":"user","uuid":"u1","timestamp":"2026-11-01T10:00:00.000Z","message":{"role":"user","content":"fix the login bug"}}"#
private let readCall = #"{"type":"assistant","uuid":"a1","timestamp":"2026-11-01T10:00:02.000Z","message":{"id":"m1","role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"Looking."},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/p/src/a.ts"}}],"stop_reason":"tool_use","usage":{"input_tokens":10,"cache_read_input_tokens":40000,"cache_creation_input_tokens":2000,"output_tokens":50}}}"#
private let readResult = #"{"type":"user","uuid":"u2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"line one"}]}}"#
private let bashCall = #"{"type":"assistant","uuid":"a2","message":{"id":"m2","role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"npm test","description":"Run tests"}}],"stop_reason":"tool_use"}}"#
private let bashFail = #"{"type":"user","uuid":"u3","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":"Exit code 1\n2 failed"}]},"toolUseResult":{"stdout":"2 failed","stderr":"","interrupted":false}}"#
private let editCall = #"{"type":"assistant","uuid":"a3","message":{"id":"m3","role":"assistant","content":[{"type":"tool_use","id":"t3","name":"Edit","input":{"file_path":"/p/src/a.ts","old_string":"a\nb\nc","new_string":"a\nB\nc"}}],"stop_reason":"tool_use"}}"#
private let done = #"{"type":"assistant","uuid":"a4","message":{"id":"m4","role":"assistant","content":[{"type":"text","text":"Fixed."}],"stop_reason":"end_turn"}}"#

@Test func promptToolsAndProse() {
  let t = timeline([prompt, readCall, readResult, done])
  #expect(t.rows.map(\.kind) == [
    .user(text: "fix the login bug", images: []),
    .prose(markdown: "Looking."),
    .tool(name: "Read", kind: .read(path: "src/a.ts"), result: ToolResult(output: "line one", isError: false, exitCode: nil, images: []), denied: false),
    .prose(markdown: "Fixed."),
  ])
  #expect(t.live.working == false)
}

@Test func bashExitCodeFromFailure() {
  let t = timeline([prompt, bashCall, bashFail])
  guard case .tool(_, .bash(let command, let summary), let result?, false) = t.rows.last?.kind else { Issue.record("no bash row"); return }
  #expect(command == "npm test")
  #expect(summary == "Run tests")
  #expect(result.exitCode == 1)
  #expect(result.isError)
  #expect(result.output == "2 failed")
}

@Test func runningToolIsLiveUntilSettled() {
  let running = timeline([prompt, bashCall])
  #expect(running.live.working)
  #expect(running.live.tool?.name == "Bash")
  #expect(running.live.tool?.detail == "npm test")
  #expect(timeline([prompt, bashCall, bashFail]).live.tool == nil)
}

@Test func editShowsDiff() {
  let t = timeline([prompt, editCall])
  guard case .tool(_, .edit(let path, let diff), _, _) = t.rows.last?.kind else { Issue.record("no edit row"); return }
  #expect(path == "src/a.ts")
  #expect(diff == [DiffLine(mark: .context, text: "a"), DiffLine(mark: .removed, text: "b"), DiffLine(mark: .added, text: "B"), DiffLine(mark: .context, text: "c")])
}

@Test func usageGivesContextAndCost() {
  let t = timeline([prompt, readCall])
  #expect(t.usage.model == "claude-opus-5-5")
  #expect(t.usage.contextTokens == 42010)
  #expect(t.usage.contextPercent == 21)
  #expect(t.usage.cost > 0)
}

@Test func usageCountsEachMessageOnce() {
  let once = timeline([prompt, readCall]).usage.cost
  #expect(timeline([prompt, readCall, readCall]).usage.cost == once)
}

@Test func deniedToolIsMarked() {
  let denial = #"{"type":"user","uuid":"u9","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":"The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed."}]}}"#
  guard case .tool(_, _, _, let denied) = timeline([prompt, bashCall, denial]).rows.last?.kind else { Issue.record("no row"); return }
  #expect(denied)
}

@Test func slashCommandEchoBecomesCommandRow() {
  let echo = #"{"type":"user","uuid":"c1","message":{"role":"user","content":"<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args></command-args>"}}"#
  let out = #"{"type":"user","uuid":"c2","message":{"role":"user","content":"<local-command-stdout>Set model to Opus 5.5</local-command-stdout>"}}"#
  #expect(timeline([echo, out]).rows.map(\.kind) == [.command(name: "/model", output: "Set model to Opus 5.5")])
}

@Test func compactBoundaryAndSummary() {
  let boundary = #"{"type":"system","subtype":"compact_boundary","uuid":"s1","content":"Conversation compacted"}"#
  let summary = #"{"type":"user","uuid":"s2","isCompactSummary":true,"message":{"role":"user","content":"This session is being continued…"}}"#
  #expect(timeline([prompt, boundary, summary]).rows.map(\.kind) == [.user(text: "fix the login bug", images: []), .compact])
}

@Test func imagesInPromptAndToolResult() {
  let png = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
  let withImage = #"{"type":"user","uuid":"u5","message":{"role":"user","content":[{"type":"text","text":"look"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(png)"}}]}}"#
  guard case .user(let text, let images) = timeline([withImage]).rows.first?.kind else { Issue.record("no row"); return }
  #expect(text == "look")
  #expect(images == [TimelineImage(mediaType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]))])
}

@Test func subagentRowsNestUnderTask() {
  let task = #"{"type":"assistant","uuid":"a5","message":{"id":"m5","role":"assistant","content":[{"type":"tool_use","id":"t5","name":"Task","input":{"description":"Verify preview","prompt":"…"}}],"stop_reason":"tool_use"}}"#
  let inner = #"{"type":"assistant","uuid":"a6","isSidechain":true,"message":{"id":"m6","role":"assistant","content":[{"type":"tool_use","id":"t6","name":"Read","input":{"file_path":"/p/b.ts"}}],"stop_reason":"tool_use"}}"#
  let t = timeline([prompt, task, inner])
  #expect(t.rows.last?.parent == "t5")
  #expect(t.rows.dropLast().last?.id == "t5")
}

@Test func metaAndMalformedLinesAreSkipped() {
  let meta = #"{"type":"user","uuid":"x","isMeta":true,"message":{"role":"user","content":"Caveat: …"}}"#
  #expect(timeline([prompt, meta, "{not json", ""]).rows.count == 1)
}

@Test func newFeedStartsEmpty() {
  #expect(SessionTimeline(root: nil).rows.isEmpty)
}

@Test func textDiffTrimsSharedLines() {
  #expect(TextDiff.lines(old: "1\n2\n3\n4\n5\nx", new: "1\n2\n3\n4\n5\ny", context: 2) ==
    [DiffLine(mark: .context, text: "4"), DiffLine(mark: .context, text: "5"), DiffLine(mark: .removed, text: "x"), DiffLine(mark: .added, text: "y")])
}

@Test func bashPermissionDeniedIsNotUserDenial() {
  let bashPermCall = #"{"type":"assistant","uuid":"a2b","message":{"id":"m2b","role":"assistant","content":[{"type":"tool_use","id":"t2b","name":"Bash","input":{"command":"./x","description":"Run script"}}],"stop_reason":"tool_use"}}"#
  let bashPermFail = #"{"type":"user","uuid":"u3b","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2b","is_error":true,"content":"bash: ./x: Permission denied"}]},"toolUseResult":{"stdout":"","stderr":"bash: ./x: Permission denied","interrupted":false}}"#
  guard case .tool(_, _, _, let denied) = timeline([prompt, bashPermCall, bashPermFail]).rows.last?.kind else { Issue.record("no bash row"); return }
  #expect(denied == false, "ordinary Permission denied should not be marked as user-denied")
}

@Test func autoModeClassifierDenialIsMarked() {
  let autoModeCall = #"{"type":"assistant","uuid":"a2c","message":{"id":"m2c","role":"assistant","content":[{"type":"tool_use","id":"t2c","name":"Edit","input":{"file_path":"/p/x.ts","old_string":"a","new_string":"b"}}],"stop_reason":"tool_use"}}"#
  let autoModeDenial = #"{"type":"user","uuid":"u3c","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2c","is_error":true,"content":"Permission for this action was denied by the Claude Code auto mode classifier because it would modify a critical file. Request access."}]}}"#
  guard case .tool(_, _, _, let denied) = timeline([prompt, autoModeCall, autoModeDenial]).rows.last?.kind else { Issue.record("no row"); return }
  #expect(denied == true, "auto mode classifier denial should be marked")
}

@Test func toolResultWithTextDoesNotCreatePrompt() {
  let toolResultWithText = #"{"type":"user","uuid":"u10","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"result text"},{"type":"text","text":"some extra text"}]}}"#
  let t = timeline([prompt, readCall, toolResultWithText])
  let userRows = t.rows.filter { if case .user = $0.kind { return true } else { return false } }
  #expect(userRows.count == 1, "only the initial prompt should be a user row, not the tool_result+text entry")
}

@Test func userInterruptSettle() {
  let interruptCall = #"{"type":"assistant","uuid":"a7","message":{"id":"m7","role":"assistant","content":[{"type":"tool_use","id":"t7","name":"Read","input":{"file_path":"/p/test.txt"}}],"stop_reason":"tool_use"}}"#
  let interrupt = #"{"type":"user","uuid":"u11","message":{"role":"user","content":"[Request interrupted by user for tool use]"}}"#
  let t = timeline([prompt, interruptCall, interrupt])
  #expect(t.live.working == false, "interrupt should settle working state")
  #expect(t.live.tool == nil, "interrupt should clear running tool")
  let interruptRows = t.rows.filter { if case .user = $0.kind { return true } else { return false } }
  #expect(interruptRows.count == 1, "interrupt entry should not create a user row")
}

@Test func multipleTasksInOneMessage() {
  let twoTasks = #"{"type":"assistant","uuid":"a8","message":{"id":"m8","role":"assistant","content":[{"type":"tool_use","id":"t8a","name":"Task","input":{"description":"First task","prompt":"…"}},{"type":"tool_use","id":"t8b","name":"Task","input":{"description":"Second task","prompt":"…"}}],"stop_reason":"tool_use"}}"#
  let sideText = #"{"type":"assistant","uuid":"a9","isSidechain":true,"message":{"id":"m9","role":"assistant","content":[{"type":"text","text":"side prose"}],"stop_reason":"end_turn"}}"#
  let t = timeline([prompt, twoTasks, sideText])
  let sideRows = t.rows.filter { $0.parent != nil }
  #expect(sideRows.count > 0, "sidechain rows should nest under a task")
  let topLevelProse = t.rows.filter { if case .prose = $0.kind { return $0.parent == nil } else { return false } }
  #expect(topLevelProse.count == 0, "sidechain prose should not appear at top level")
}

@Test func settledTaskStillParentsSidechainRows() {
  let task1Call = #"{"type":"assistant","uuid":"a10","message":{"id":"m10","role":"assistant","content":[{"type":"tool_use","id":"t10","name":"Task","input":{"description":"Task 1","prompt":"…"}},{"type":"tool_use","id":"t11","name":"Task","input":{"description":"Task 2","prompt":"…"}}],"stop_reason":"tool_use"}}"#
  let task1Settle = #"{"type":"user","uuid":"u20","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t10","content":"Task 1 result"}]}}"#
  let sideWithTool = #"{"type":"assistant","uuid":"a11","isSidechain":true,"message":{"id":"m11","role":"assistant","content":[{"type":"text","text":"checking"},{"type":"tool_use","id":"t12","name":"Read","input":{"file_path":"/p/check.txt"}}],"stop_reason":"end_turn"}}"#
  let workingBefore = timeline([prompt, task1Call]).live.working
  let t = timeline([prompt, task1Call, task1Settle, sideWithTool])
  #expect(t.rows.filter { if case .prose = $0.kind { return $0.parent == nil } else { return false } }.count == 0, "sidechain prose should not be top-level")
  let sideToolRow = t.rows.first { if case .tool(_, _, _, _) = $0.kind { return $0.id == "t12" } else { return false } }
  #expect(sideToolRow?.parent == "t11", "sidechain tool nests under remaining open Task t11")
  #expect(t.live.working == workingBefore, "sidechain end_turn should not affect working (settled task context)")
}

@Test func orphanSidechainToolUseWithoutTaskContext() {
  let orphanTool = #"{"type":"assistant","uuid":"a14","isSidechain":true,"message":{"id":"m14","role":"assistant","content":[{"type":"tool_use","id":"t14","name":"Read","input":{"file_path":"/p/x.txt"}}],"stop_reason":"tool_use"}}"#
  let orphanResult = #"{"type":"user","uuid":"u22","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t14","content":"should not crash"}]}}"#
  let t = timeline([prompt, orphanTool, orphanResult])
  #expect(t.rows.count == 1, "only initial prompt, orphan sidechain tool_use is skipped")
}

@Test func bashRowUntouchedByOrphanSidechainToolResult() {
  let bashCall = #"{"type":"assistant","uuid":"a15","message":{"id":"m15","role":"assistant","content":[{"type":"tool_use","id":"t15","name":"Bash","input":{"command":"echo test","description":"Test"}}],"stop_reason":"tool_use"}}"#
  let bashResult = #"{"type":"user","uuid":"u23","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t15","content":"test"}]}}"#
  let orphanTool = #"{"type":"assistant","uuid":"a16","isSidechain":true,"message":{"id":"m16","role":"assistant","content":[{"type":"tool_use","id":"t16","name":"Read","input":{"file_path":"/p/y.txt"}}],"stop_reason":"tool_use"}}"#
  let orphanResult = #"{"type":"user","uuid":"u24","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t16","content":"orphan"}]}}"#
  let t = timeline([prompt, bashCall, bashResult, orphanTool, orphanResult])
  guard case .tool(_, .bash, let result?, _) = t.rows.first(where: { $0.id == "t15" })?.kind else { Issue.record("no bash row"); return }
  #expect(result.output == "test", "bash tool result untouched by orphan sidechain settle attempt")
}

@Test func settledTaskParentsLaterSidechain() {
  let taskCall = #"{"type":"assistant","uuid":"a12","message":{"id":"m12","role":"assistant","content":[{"type":"tool_use","id":"t13","name":"Task","input":{"description":"Single task","prompt":"…"}}],"stop_reason":"tool_use"}}"#
  let taskSettle = #"{"type":"user","uuid":"u21","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t13","content":"Done"}]}}"#
  let sideText = #"{"type":"assistant","uuid":"a13","isSidechain":true,"message":{"id":"m13","role":"assistant","content":[{"type":"text","text":"final note"}],"stop_reason":"end_turn"}}"#
  let t = timeline([prompt, taskCall, taskSettle, sideText])
  let topLevelRows = t.rows.filter { $0.parent == nil }
  #expect(topLevelRows.count == 2, "only prompt and task tool rows at top level")
  let sideProseRows = t.rows.filter { if case .prose = $0.kind { return true } else { return false } }
  #expect(sideProseRows.count == 1, "one prose row (sidechain)")
  #expect(sideProseRows.first?.parent == "t13", "sidechain prose nested under settled task")
}

private let notification = #"{"type":"user","uuid":"n1","timestamp":"2026-11-01T10:00:05.000Z","origin":{"kind":"task-notification"},"promptSource":"system","message":{"role":"user","content":"<task-notification>\n<task-id>a1</task-id>\n<status>stopped</status>\n</task-notification>"}}"#

@Test func aBackgroundTasksNotificationIsNotSomethingTheUserSaid() {
  let t = timeline([prompt, done, notification])
  #expect(t.rows.map(\.kind) == [.user(text: "fix the login bug", images: []), .prose(markdown: "Fixed.")])
  // After a resume nothing may answer it, so it must not read as Claude working.
  #expect(t.live.working == false)
}

@Test func aNotificationWithoutAnOriginIsStillOne() {
  let older = #"{"type":"user","uuid":"n2","message":{"role":"user","content":"<task-notification><status>completed</status></task-notification>"}}"#
  #expect(timeline([older]).rows.isEmpty)
}

@Test func aPromptQuotingANotificationIsStillThePrompt() {
  let quoted = #"{"type":"user","uuid":"n3","origin":{"kind":"human"},"message":{"role":"user","content":"<task-notification> is showing in the view"}}"#
  #expect(timeline([quoted]).rows.map(\.kind) == [.user(text: "<task-notification> is showing in the view", images: [])])
}

@Test func aBangCommandIsACommandRowWithItsOutput() {
  let input = #"{"type":"user","uuid":"b1","message":{"role":"user","content":"<bash-input>git status</bash-input>"}}"#
  let output = #"{"type":"user","uuid":"b2","message":{"role":"user","content":"<bash-stdout>clean</bash-stdout><bash-stderr>warn</bash-stderr>"}}"#
  #expect(timeline([input, output]).rows.map(\.kind) == [.command(name: "! git status", output: "clean\nwarn")])
  let silent = #"{"type":"user","uuid":"b3","message":{"role":"user","content":"<bash-stdout></bash-stdout><bash-stderr></bash-stderr>"}}"#
  #expect(timeline([input, silent]).rows.map(\.kind) == [.command(name: "! git status", output: nil)])
  // Neither reads as Claude working: Claude didn't run it.
  #expect(timeline([input, output]).live.working == false)
}
