import Foundation
import Testing
@testable import GlanceCore

private func row(_ id: String, _ kind: TimelineRow.Kind, parent: String? = nil) -> TimelineRow {
  TimelineRow(id: id, kind: kind, time: nil, parent: parent)
}
private func user(_ id: String, _ text: String = "ask") -> TimelineRow { row(id, .user(text: text, images: [])) }
private func prose(_ id: String, _ text: String? = nil, parent: String? = nil) -> TimelineRow {
  row(id, .prose(markdown: text ?? id), parent: parent)
}
private func read(_ id: String) -> TimelineRow { row(id, .tool(name: "Read", kind: .read(path: id), result: nil, denied: false)) }

@Test func onlyTheLastProseOfAFinishedTurnCounts() {
  let rows = [user("u1"), prose("a"), read("r"), prose("b"), user("u2"), prose("c")]
  #expect(ExplainerTurns.finishedReplies(rows, working: true) == ["b"])
  #expect(ExplainerTurns.finishedReplies(rows, working: false) == ["b", "c"])
  #expect(ExplainerTurns.newestFinished(rows, working: true) == "b")
  #expect(ExplainerTurns.newestFinished(rows, working: false) == "c")
}

@Test func aSubagentsProseIsNeverAReply() {
  let rows = [user("u1"), prose("mine"), row("t", .tool(name: "Task", kind: .task(summary: "x"), result: nil, denied: false)), prose("theirs", parent: "t")]
  #expect(ExplainerTurns.finishedReplies(rows, working: false) == ["mine"])
  #expect(ExplainerTurns.turn(endingAt: "theirs", rows: rows) == nil)
}

@Test func aTurnWithNoProseHasNoReply() {
  #expect(ExplainerTurns.finishedReplies([user("u1"), read("r"), user("u2")], working: false).isEmpty)
}

@Test func aTurnHoldsItsAskAndItsRowsOnly() throws {
  let rows = [user("u1", "first"), prose("a"), user("u2", "second"), prose("b"), read("r"), prose("c"), user("u3"), prose("d")]
  let turn = try #require(ExplainerTurns.turn(endingAt: "c", rows: rows))
  #expect(turn.ask == "second")
  #expect(turn.rows.map(\.id) == ["b", "r", "c"])
  #expect(turn.prose == ["b", "c"])
  #expect(turn.reply == "c")
  #expect(ExplainerTurns.turn(endingAt: "b", rows: rows) == nil, "not the turn's last prose")
}

@Test func aTranscriptCutBeforeThePromptStillHasATurn() throws {
  let turn = try #require(ExplainerTurns.turn(endingAt: "a", rows: [read("r"), prose("a")]))
  #expect(turn.ask == nil)
  #expect(turn.rows.map(\.id) == ["r", "a"])
}

@Test func theAutomaticRules() {
  let long = Array(repeating: "word", count: 60).joined(separator: " ")
  let short = Array(repeating: "word", count: 59).joined(separator: " ")
  #expect(ExplainerTurns.automatic(reply: "a", markdown: long, ended: ["a"]) == .page)
  #expect(ExplainerTurns.automatic(reply: "a", markdown: short, ended: ["a"]) == .readAloud)
  #expect(ExplainerTurns.automatic(reply: "a", markdown: long, ended: []) == .nothing, "interrupted")
}

private let endTurn = #"{"type":"assistant","uuid":"a1","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"Done."}],"stop_reason":"end_turn"}}"#

@Test func theTimelineRecordsAnEndedTurn() {
  var t = SessionTimeline(root: nil)
  t.ingest(line: #"{"type":"user","uuid":"u1","message":{"role":"user","content":"go"}}"#)
  t.ingest(line: endTurn)
  #expect(t.endedTurns == ["a1-0"])
}

@Test func anInterruptedTurnIsNotEnded() {
  var t = SessionTimeline(root: nil)
  t.ingest(line: #"{"type":"user","uuid":"u1","message":{"role":"user","content":"go"}}"#)
  t.ingest(line: #"{"type":"assistant","uuid":"a1","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"Working."}],"stop_reason":"tool_use"}}"#)
  t.ingest(line: #"{"type":"user","uuid":"u2","message":{"role":"user","content":"[Request interrupted by user]"}}"#)
  #expect(t.endedTurns.isEmpty)
  #expect(ExplainerTurns.finishedReplies(t.rows, working: t.live.working) == ["a1-0"], "Explain by hand still works")
}

@Test func anEndWithNoNewProseDoesNotMarkAnEarlierTurn() {
  var t = SessionTimeline(root: nil)
  t.ingest(line: #"{"type":"user","uuid":"u1","message":{"role":"user","content":"one"}}"#)
  t.ingest(line: endTurn)
  t.ingest(line: #"{"type":"user","uuid":"u2","message":{"role":"user","content":"two"}}"#)
  t.ingest(line: #"{"type":"assistant","uuid":"a2","message":{"id":"m2","role":"assistant","content":[],"stop_reason":"end_turn"}}"#)
  #expect(t.endedTurns == ["a1-0"])
}

@Test func stepsFoldIntoOneLinePerShownReply() {
  let rows = [user("u1"), prose("a"), read("r1"), read("r2"), row("b", .tool(name: "Bash", kind: .bash(command: "x", summary: nil), result: nil, denied: false)), prose("c"), user("u2"), read("r3"), prose("d")]
  let blocks = TimelineLayout.blocks(rows)
  let fold = ExplainerTurns.fold(blocks: blocks, replies: ["c"], open: [])
  #expect(fold.lines["a"] == .init(reply: "c", count: 3, open: false))
  #expect(fold.hidden == ["a", "g-r1", "b"])
  let opened = ExplainerTurns.fold(blocks: blocks, replies: ["c"], open: ["c"])
  #expect(opened.lines["a"]?.open == true)
  #expect(opened.hidden.isEmpty)
  #expect(ExplainerTurns.fold(blocks: blocks, replies: [], open: []) == ExplainerStepsFold())
}

@Test func aReplyWithNoStepsHasNoFoldLine() {
  let blocks = TimelineLayout.blocks([user("u1"), prose("a")])
  #expect(ExplainerTurns.fold(blocks: blocks, replies: ["a"], open: []) == ExplainerStepsFold())
}

@Test func onlyAReplyFinishedAfterOpeningActsAlone() {
  let opened = Date(timeIntervalSince1970: 1000)
  func at(_ seconds: Double?) -> TimelineRow {
    TimelineRow(id: "r", kind: .prose(markdown: "x"), time: seconds.map(Date.init(timeIntervalSince1970:)), parent: nil)
  }
  #expect(ExplainerTurns.finishedSince(opened, reply: at(1001)))
  #expect(!ExplainerTurns.finishedSince(opened, reply: at(999)), "already in the transcript")
  #expect(!ExplainerTurns.finishedSince(opened, reply: at(nil)), "no time: never on its own")
}
