import Foundation
import Testing
@testable import GlanceCore

private let session = [
  #"{"type":"queue-operation"}"#,
  #"{"type":"user","cwd":"/p","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
  #"{"type":"user","cwd":"/p","message":{"role":"user","content":[{"type":"text","text":"[Razor Code: src/a.ts, lines 3–5 selected] why is this slow?"}]}}"#,
  #"{"type":"attachment","attachment":{}}"#,
  #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"}]}}"#,
  #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/p/src/a.ts"}}],"stop_reason":"tool_use"}}"#,
  #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"body"}]}}"#,
  #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"rm -rf build\necho done"}}],"stop_reason":"tool_use"}}"#,
  #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":"Permission for this action was denied by the Claude Code auto mode classifier. Reason: dangerous"}]}}"#,
  #"{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"subagent"}]}}"#,
  #"{"type":"user","isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"meta reminder"}]}}"#,
  #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"The loop is quadratic.\n\n```ts\nfor (;;) {}\n```"}],"stop_reason":"end_turn"}}"#,
].joined(separator: "\n")

@Test func threadReadsPromptsToolsDenialsAndReplies() {
  let thread = ChatTranscript.thread(jsonl: session, root: "/p")
  #expect(thread.items == [
    .user(text: "why is this slow?", context: "src/a.ts, lines 3–5 selected"),
    .tool(name: "Read", detail: "src/a.ts"),
    .denied(name: "Bash", detail: "rm -rf build"),
    .assistant(blocks: Blocks.split("The loop is quadratic.\n\n```ts\nfor (;;) {}\n```")),
  ])
  #expect(thread.working == false)
  #expect(thread.truncated == false)
}

@Test func aPromptWithoutItsFinalAnswerIsWorking() {
  let pending = session + "\n" + #"{"type":"user","message":{"role":"user","content":"and now?"}}"#
  let thread = ChatTranscript.thread(jsonl: pending, root: "/p")
  #expect(thread.working)
  #expect(thread.items.last == .user(text: "and now?", context: nil))
}

@Test func aFailedToolThatAutoModeDidNotRefuseStaysATool() {
  let jsonl = [
    #"{"type":"user","message":{"role":"user","content":"read it"}}"#,
    #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/elsewhere/x.md"}}],"stop_reason":"tool_use"}}"#,
    #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"File does not exist."}]}}"#,
  ].joined(separator: "\n")
  let thread = ChatTranscript.thread(jsonl: jsonl, root: "/p")
  #expect(thread.items.last == .tool(name: "Read", detail: "x.md"))
  #expect(thread.working)
}

@Test func aCutFirstLineFromATailReadIsSkipped() {
  let cut = #"ssistant","message":{"role":"assistant","content":[{"type":"text","text":"half"}]}}"# + "\n" + session
  let thread = ChatTranscript.thread(jsonl: cut, root: "/p", truncated: true)
  #expect(thread.items.count == 4)
  #expect(thread.truncated)
}

@Test func toolDetailsAreOneShortLine() {
  let long = String(repeating: "x", count: 120)
  let jsonl = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t","name":"Bash","input":{"command":"echo \#(long)"}}],"stop_reason":"tool_use"}}"#
  guard case .tool(_, let detail) = ChatTranscript.thread(jsonl: jsonl, root: nil).items.first else {
    Issue.record("no tool row"); return
  }
  #expect(detail.count == 80)
  #expect(detail.hasSuffix("…"))
}

@Test func contextLinesNameTheFileAndSelection() {
  #expect(ChatMessage.context(file: nil, lines: 1...2) == nil)
  #expect(ChatMessage.context(file: "a.ts", lines: nil) == "a.ts")
  #expect(ChatMessage.context(file: "a.ts", lines: 4...4) == "a.ts, line 4 selected")
  #expect(ChatMessage.context(file: "a.ts", lines: 4...9) == "a.ts, lines 4–9 selected")
}

@Test func composeAndSplitRoundTrip() {
  let sent = ChatMessage.compose("fix it", context: "a.ts, line 4 selected")
  #expect(sent == "[Razor Code: a.ts, line 4 selected] fix it")
  let parts = ChatMessage.split(sent)
  #expect(parts.text == "fix it")
  #expect(parts.context == "a.ts, line 4 selected")
  #expect(ChatMessage.compose("fix it", context: nil) == "fix it")
  #expect(ChatMessage.split("[not ours] hi").text == "[not ours] hi")
  #expect(ChatMessage.split("[not ours] hi").context == nil)
}

@Test func composeKeepsMultiLineTextVerbatim() {
  let text = "line one\n\"quoted\" \\ back\nline three"
  let sent = ChatMessage.compose(text, context: "a.ts")
  #expect(ChatMessage.split(sent).text == text)
}

@Test func payloadNamesEachKind() throws {
  let thread = ChatTranscript.thread(jsonl: session, root: "/p")
  let items = try #require(thread.payload["items"] as? [[String: Any]])
  #expect(items.map { $0["kind"] as? String } == ["user", "tool", "denied", "assistant"])
  #expect(items[0]["context"] as? String == "src/a.ts, lines 3–5 selected")
  let blocks = try #require(items[3]["blocks"] as? [[String: Any]])
  #expect(blocks.map { $0["kind"] as? String } == ["paragraph", "code"])
  #expect(thread.payload["working"] as? Bool == false)
  #expect(JSONSerialization.isValidJSONObject(thread.payload))
}
