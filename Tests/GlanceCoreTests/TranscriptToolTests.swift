import Foundation
import Testing
@testable import GlanceCore

private let toolUse = #"{"type":"assistant","cwd":"/a","message":{"stop_reason":"tool_use","content":[{"type":"text","text":"Running it."},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]}}"#
private let toolResult = #"{"type":"user","cwd":"/a","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok"}]}}"#
private let sidechain = #"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"tool_use","id":"toolu_9","name":"Read","input":{}}]}}"#

@Test func aToolUseIsPendingAndItsResultSettlesIt() {
  #expect(Transcript.toolEvents(line: toolUse)
    == [ToolEvent(kind: .pending(ToolCall(id: "toolu_1", name: "Bash", input: .object(["command": .string("ls")]))),
                  cwd: "/a")])
  #expect(Transcript.toolEvents(line: toolResult) == [ToolEvent(kind: .settled(id: "toolu_1"), cwd: "/a")])
}

@Test func subagentAndPlainLinesHaveNoToolEvents() {
  #expect(Transcript.toolEvents(line: sidechain).isEmpty)
  #expect(Transcript.toolEvents(line: #"{"type":"user","message":{"content":"hi"}}"#).isEmpty)
  #expect(Transcript.toolEvents(line: "not json").isEmpty)
}

@Test func theTailReportsToolsInOrderWithTheFilesCwd() {
  var tail = TranscriptTail()
  let lines = #"{"type":"user","cwd":"/a","message":{"content":"hi"}}"# + "\n"
    + toolUse.replacingOccurrences(of: #""cwd":"/a","#, with: "") + "\n" + toolResult + "\n"
  let data = Data(lines.utf8)
  let events = tail.allEvents(in: "/p/s.jsonl", size: UInt64(data.count)) { from, to in
    data.subdata(in: Int(from)..<Int(to))
  }
  #expect(events == [
    .turn(TurnEvent(kind: .prompt, cwd: "/a")),
    .tool(ToolEvent(kind: .pending(ToolCall(id: "toolu_1", name: "Bash", input: .object(["command": .string("ls")]))),
                    cwd: "/a")),
    .tool(ToolEvent(kind: .settled(id: "toolu_1"), cwd: "/a")),
  ])
}
