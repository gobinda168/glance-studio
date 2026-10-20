import Testing
@testable import GlanceCore

private func prompt(_ text: String, sidechain: Bool = false) -> String {
  #"{"type":"user","isSidechain":\#(sidechain),"message":{"role":"user","content":"\#(text)"}}"#
}
private func assistant(_ blocks: String..., sidechain: Bool = false) -> String {
  #"{"type":"assistant","isSidechain":\#(sidechain),"message":{"role":"assistant","content":[\#(blocks.joined(separator: ","))]}}"#
}
private func result(_ id: String, error: Bool) -> String {
  #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)","is_error":\#(error),"content":"x"}]}}"#
}
private func edit(_ id: String, _ path: String, old: String, new: String, all: Bool = false) -> String {
  #"{"type":"tool_use","id":"\#(id)","name":"Edit","input":{"file_path":"\#(path)","old_string":"\#(old)","new_string":"\#(new)","replace_all":\#(all)}}"#
}
private func write(_ id: String, _ path: String, content: String) -> String {
  #"{"type":"tool_use","id":"\#(id)","name":"Write","input":{"file_path":"\#(path)","content":"\#(content)"}}"#
}
private func lines(_ entries: String...) -> String { entries.joined(separator: "\n") }

@Test func anEditToolCallBecomesAReplaceEdit() {
  let jsonl = lines(prompt("go"), assistant(edit("t1", "/p/a.swift", old: "foo", new: "bar")))
  #expect(ClaudeEdits.latestEdits(jsonl: jsonl) == [FileEdit(path: "/p/a.swift", change: .replace(old: "foo", new: "bar", replaceAll: false))])
}

@Test func replaceAllAndMultiLineStringsSurvive() {
  let jsonl = lines(prompt("go"), assistant(edit("t1", "/p/a.swift", old: #"a\nb"#, new: #"c\nd"#, all: true)))
  #expect(ClaudeEdits.latestEdits(jsonl: jsonl) == [FileEdit(path: "/p/a.swift", change: .replace(old: "a\nb", new: "c\nd", replaceAll: true))])
}

@Test func aWriteToolCallBecomesAWriteEdit() {
  let jsonl = lines(prompt("go"), assistant(write("t1", "/p/new.txt", content: "hello")))
  #expect(ClaudeEdits.latestEdits(jsonl: jsonl) == [FileEdit(path: "/p/new.txt", change: .write(content: "hello"))])
}

@Test func aMultiEditBecomesOneReplaceEditPerItem() {
  let multi = #"{"type":"tool_use","id":"t1","name":"MultiEdit","input":{"file_path":"/p/a.swift","edits":[{"old_string":"a","new_string":"b"},{"old_string":"c","new_string":"d","replace_all":true}]}}"#
  let jsonl = lines(prompt("go"), assistant(multi))
  #expect(ClaudeEdits.latestEdits(jsonl: jsonl) == [
    FileEdit(path: "/p/a.swift", change: .replace(old: "a", new: "b", replaceAll: false)),
    FileEdit(path: "/p/a.swift", change: .replace(old: "c", new: "d", replaceAll: true)),
  ])
}

@Test func onlyTheLatestTurnWithEditsCounts() {
  let jsonl = lines(
    prompt("one"), assistant(edit("t1", "/p/a.swift", old: "a", new: "b")),
    prompt("two"), assistant(edit("t2", "/p/b.swift", old: "c", new: "d")))
  #expect(ClaudeEdits.latestEdits(jsonl: jsonl).map(\.path) == ["/p/b.swift"])
}

@Test func aLaterTurnWithoutEditsKeepsTheEarlierMarks() {
  let jsonl = lines(
    prompt("one"), assistant(edit("t1", "/p/a.swift", old: "a", new: "b")),
    prompt("explain it"), assistant(#"{"type":"text","text":"It does x."}"#))
  #expect(ClaudeEdits.latestEdits(jsonl: jsonl).map(\.path) == ["/p/a.swift"])
}

@Test func toolResultsAreNotPromptsAndDontEndATurn() {
  let jsonl = lines(
    prompt("go"), assistant(edit("t1", "/p/a.swift", old: "a", new: "b")), result("t1", error: false),
    assistant(edit("t2", "/p/b.swift", old: "c", new: "d")), result("t2", error: false))
  #expect(ClaudeEdits.latestEdits(jsonl: jsonl).map(\.path) == ["/p/a.swift", "/p/b.swift"])
}

@Test func failedEditsAreDropped() {
  let jsonl = lines(
    prompt("go"), assistant(edit("t1", "/p/a.swift", old: "a", new: "b"), edit("t2", "/p/b.swift", old: "c", new: "d")),
    result("t1", error: true), result("t2", error: false))
  #expect(ClaudeEdits.latestEdits(jsonl: jsonl).map(\.path) == ["/p/b.swift"])
}

@Test func aTurnWhoseEditsAllFailedFallsBackToTheEarlierTurn() {
  let jsonl = lines(
    prompt("one"), assistant(edit("t1", "/p/a.swift", old: "a", new: "b")),
    prompt("two"), assistant(edit("t2", "/p/b.swift", old: "c", new: "d")), result("t2", error: true))
  #expect(ClaudeEdits.latestEdits(jsonl: jsonl).map(\.path) == ["/p/a.swift"])
}

@Test func subagentEditsCountButSubagentPromptsDontStartATurn() {
  let jsonl = lines(
    prompt("go"), assistant(edit("t1", "/p/a.swift", old: "a", new: "b")),
    prompt("subagent task", sidechain: true), assistant(edit("t2", "/p/b.swift", old: "c", new: "d"), sidechain: true))
  #expect(ClaudeEdits.latestEdits(jsonl: jsonl).map(\.path) == ["/p/a.swift", "/p/b.swift"])
}

@Test func otherToolsMetaEntriesAndGarbageAreIgnored() {
  let read = #"{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/p/a.swift"}}"#
  let bash = #"{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"ls"}}"#
  let meta = #"{"type":"assistant","isMeta":true,"message":{"content":[\#(edit("t3", "/p/m.swift", old: "a", new: "b"))]}}"#
  let jsonl = lines(prompt("go"), assistant(read, bash), meta, "not json", "{}", "")
  #expect(ClaudeEdits.latestEdits(jsonl: jsonl).isEmpty)
  #expect(ClaudeEdits.latestEdits(jsonl: "").isEmpty)
}

@Test func editedPathsCoverEveryTurnOnceAndSkipFailures() {
  let jsonl = lines(
    prompt("one"), assistant(edit("t1", "/p/b.swift", old: "a", new: "b"), write("t2", "/p/a.md", content: "x")),
    prompt("two"), assistant(edit("t3", "/p/b.swift", old: "b", new: "c")),
    assistant(edit("t4", "/p/sub.swift", old: "s", new: "t"), sidechain: true),
    assistant(edit("t5", "/p/broken.swift", old: "z", new: "y")), result("t5", error: true))
  #expect(ClaudeEdits.editedPaths(jsonl: jsonl) == ["/p/a.md", "/p/b.swift", "/p/sub.swift"])
  #expect(ClaudeEdits.editedPaths(jsonl: prompt("hi")) == [])
}
