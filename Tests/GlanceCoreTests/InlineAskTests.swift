import Foundation
import Testing
@testable import GlanceCore

private let request = InlineAsk.Request(
  id: "a1", path: "Sources/App.swift", start: 3, end: 4, text: "  let a = 1\n  let b = 2",
  before: "import Foundation\nfunc f() {", after: "}", question: "Why two lets?")

private func fixture(_ name: String) throws -> String {
  let url = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/\(name)")
  return try String(contentsOf: url, encoding: .utf8)
}

private func delta(_ text: String) -> String {
  #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"#
    + String(decoding: try! JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed), as: UTF8.self) + "}}}"
}

private let textStart = #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}"#
private let success = #"{"type":"result","subtype":"success","is_error":false,"result":"ok"}"#

private func texts(_ events: [InlineAsk.Event]) -> String {
  events.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
}

// MARK: Command line and prompt

@Test func runsHeadlessReadOnlyWithoutHooksOrSessions() {
  let args = InlineAsk.arguments()
  #expect(args.starts(with: ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                             "--include-partial-messages", "--no-session-persistence"]))
  let tools = try! #require(args.firstIndex(of: "--tools"))
  #expect(Array(args[tools + 1...tools + 3]) == ["Read", "Grep", "Glob"])
  let settings = try! #require(args.firstIndex(of: "--settings"))
  #expect(args[settings + 1] == #"{"disableAllHooks":true}"#)
  #expect(args.contains("--strict-mcp-config"))
  let rules = try! #require(args.firstIndex(of: "--append-system-prompt"))
  #expect(args[rules + 1] == InlineAsk.rules)
  #expect(InlineAsk.rules.contains("<replacement>"))
}

@Test func firstMessageNumbersTheSelectionAndItsContext() {
  let message = InlineAsk.firstMessage(request)
  #expect(message == """
    File: Sources/App.swift
    The user selected lines 3-4. Around them:
    1| import Foundation
    2| func f() {
    3> \u{20} let a = 1
    4> \u{20} let b = 2
    5| }

    Question: Why two lets?
    """)
}

@Test func firstMessageWithoutContextAtTheFileEdges() {
  let edge = InlineAsk.Request(id: "a", path: "x.txt", start: 1, end: 1, text: "only", before: "", after: "", question: "Hi")
  #expect(InlineAsk.firstMessage(edge) == "File: x.txt\nThe user selected line 1. Around it:\n1> only\n\nQuestion: Hi")
}

@Test func userLineIsOneStreamJSONMessage() throws {
  let line = InlineAsk.userLine("two\nlines")
  #expect(!line.contains("\n"))
  let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
  #expect(object["type"] as? String == "user")
  let message = try #require(object["message"] as? [String: Any])
  #expect(message["role"] as? String == "user")
  #expect(message["content"] as? String == "two\nlines")
}

@Test func findsClaudeOnThePathFirst() {
  let found = InlineAsk.findClaude(path: "/a:/b/bin", home: "/h", exists: { ["/b/bin/claude", "/h/.local/bin/claude"].contains($0) })
  #expect(found == "/b/bin/claude")
}

@Test func findsClaudeInItsUsualInstallPlaces() {
  #expect(InlineAsk.findClaude(path: nil, home: "/h", exists: { $0 == "/h/.claude/local/claude" }) == "/h/.claude/local/claude")
  #expect(InlineAsk.findClaude(path: "/a", home: "/h", exists: { $0 == "/opt/homebrew/bin/claude" }) == "/opt/homebrew/bin/claude")
  #expect(InlineAsk.findClaude(path: "/a", home: "/h", exists: { _ in false }) == nil)
}

// MARK: Parser

@Test func parsesARecordedEditRun() throws {
  var parser = InlineAsk.Parser(folder: "/project")
  var events: [InlineAsk.Event] = []
  for line in try fixture("inline-ask-edit.jsonl").split(separator: "\n") { events += parser.feed(String(line)) }

  #expect(events.contains(.tool("Reading Sources/GlanceCore/EditorBridgeCommand.swift…")))
  let shown = texts(events)
  #expect(shown.hasPrefix("This enum defines editor bridge commands."))
  #expect(shown.contains("I also need to update line 24"))
  #expect(!shown.contains("replacement>"))
  #expect(!shown.contains("claudeFilePaths([String])"))
  #expect(events.last == .done(replacement: "  case claudeFilePaths([String])"))
}

@Test func hidesAReplacementTagSplitAcrossDeltas() {
  var parser = InlineAsk.Parser(folder: "/p")
  var events: [InlineAsk.Event] = []
  for chunk in ["Here:\n<repl", "acement>\nnew()", "\n</replace", "ment>\nDone <b>.", "</b>"] { events += parser.feed(delta(chunk)) }
  events += parser.feed(success)
  #expect(texts(events) == "Here:\n\nDone <b>.</b>")
  #expect(events.last == .done(replacement: "new()"))
}

@Test func aLoneLessThanSignIsShownOnceItCanNoLongerBeATag() {
  var parser = InlineAsk.Parser(folder: "/p")
  var events = parser.feed(delta("a <"))
  #expect(texts(events) == "a ")
  events = parser.feed(delta(" b"))
  #expect(texts(events) == "< b")
}

@Test func separatesTextBlocksOfOneTurn() {
  var parser = InlineAsk.Parser(folder: "/p")
  var events = parser.feed(textStart) + parser.feed(delta("First."))
  events += parser.feed(textStart) + parser.feed(delta("Second."))
  #expect(texts(events) == "First.\n\nSecond.")
}

@Test func aFollowUpTurnStartsClean() {
  var parser = InlineAsk.Parser(folder: "/p")
  _ = parser.feed(textStart) + parser.feed(delta("One <replacement>\nx")) + parser.feed(success)
  let events = parser.feed(textStart) + parser.feed(delta("Two")) + parser.feed(success)
  #expect(texts(events) == "Two")
  #expect(events.last == .done(replacement: nil))
}

@Test func labelsSearchTools() {
  var parser = InlineAsk.Parser(folder: "/p")
  let grep = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Grep","input":{"pattern":"foo"}}]}}"#
  let glob = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Glob","input":{"pattern":"**/*.swift"}}]}}"#
  let read = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/elsewhere/a.txt"}}]}}"#
  #expect(parser.feed(grep) == [.tool("Searching for “foo”…")])
  #expect(parser.feed(glob) == [.tool("Finding **/*.swift…")])
  #expect(parser.feed(read) == [.tool("Reading /elsewhere/a.txt…")])
}

@Test func anErrorResultFails() {
  var parser = InlineAsk.Parser(folder: "/p")
  let error = #"{"type":"result","subtype":"success","is_error":true,"result":"Invalid API key · Please run /login"}"#
  #expect(parser.feed(error) == [.failed("Invalid API key · Please run /login")])
  let during = #"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["boom"]}"#
  #expect(parser.feed(during) == [.failed("boom")])
}

@Test func ignoresNoiseAndBrokenLines() {
  var parser = InlineAsk.Parser(folder: "/p")
  #expect(parser.feed("not json").isEmpty)
  #expect(parser.feed(#"{"type":"system","subtype":"init"}"#).isEmpty)
  #expect(parser.feed(#"{"type":"rate_limit_event"}"#).isEmpty)
}

@Test func replacementDropsOnlyTheNewlinesAroundIt() {
  #expect(InlineAsk.replacement(in: "x <replacement>\n  a\n\n  b\n</replacement> y") == "  a\n\n  b")
  #expect(InlineAsk.replacement(in: "<replacement>a</replacement><replacement>b</replacement>") == "a")
  #expect(InlineAsk.replacement(in: "no block") == nil)
}

// MARK: Events on the wire

@Test func doneCarriesWhatTheEditWasMadeFor() {
  let object = InlineAsk.eventObject(.done(replacement: "new"), for: request)
  #expect(object["id"] as? String == "a1")
  #expect(object["kind"] as? String == "done")
  #expect(object["replacement"] as? String == "new")
  #expect(object["start"] as? Int == 3)
  #expect(object["end"] as? Int == 4)
  #expect(object["originalText"] as? String == request.text)
  #expect(InlineAsk.eventObject(.done(replacement: nil), for: request)["replacement"] == nil)
}

@Test func otherEventsOnTheWire() {
  #expect(InlineAsk.eventObject(.text("hi"), for: request)["text"] as? String == "hi")
  #expect(InlineAsk.eventObject(.tool("Reading a…"), for: request)["label"] as? String == "Reading a…")
  let failed = InlineAsk.eventObject(.failed("nope"), for: request)
  #expect(failed["kind"] as? String == "failed")
  #expect(failed["message"] as? String == "nope")
}
