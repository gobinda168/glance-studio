import Testing
@testable import GlanceCore

private func line(_ json: String) -> String { json }

private let transcript = [
  #"{"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>x</local-command-caveat>"}}"#,
  #"{"type":"user","message":{"role":"user","content":"first question"}}"#,
  #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Old answer."}]}}"#,
  #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"how does auth work?"}]}}"#,
  #"{"type":"attachment","attachment":{}}"#,
  #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"}]}}"#,
  #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Let me look."}]}}"#,
  #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{}}]}}"#,
  #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"file body"}]}}"#,
  #"{"type":"user","isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"meta reminder"}]}}"#,
  #"{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"subagent chatter"}]}}"#,
  #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"So login is a three-hop dance."}]}}"#,
  "not json at all",
  "",
].joined(separator: "\n")

@Test func lastReplyJoinsTextAfterTheLastRealPrompt() {
  #expect(Transcript.lastReply(jsonl: transcript) == "Let me look.\n\nSo login is a three-hop dance.")
}

@Test func lastReplyIsNilWhenTheTurnHasNoTextYet() {
  let pending = transcript + "\n" + #"{"type":"user","message":{"role":"user","content":"next"}}"#
  #expect(Transcript.lastReply(jsonl: pending) == nil)
}

@Test func lastReplyIgnoresGarbage() {
  #expect(Transcript.lastReply(jsonl: "") == nil)
  #expect(Transcript.lastReply(jsonl: "{\n}\n[1,2]") == nil)
}

private let cwd = "/Users/me/Code/app"

@Test func turnEventSeesPromptsAndFinishedTurns() {
  #expect(Transcript.turnEvent(line: #"{"type":"user","cwd":"\#(cwd)","message":{"content":"hi"}}"#)
    == TurnEvent(kind: .prompt, cwd: cwd))
  #expect(Transcript.turnEvent(line: #"{"type":"user","cwd":"\#(cwd)","message":{"content":[{"type":"text","text":"hi"}]}}"#)
    == TurnEvent(kind: .prompt, cwd: cwd))
  #expect(Transcript.turnEvent(line: #"{"type":"assistant","cwd":"\#(cwd)","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"x"}]}}"#)
    == TurnEvent(kind: .done, cwd: cwd))
}

@Test func turnEventIgnoresToolUseAndPauses() {
  #expect(Transcript.turnEvent(line: #"{"type":"assistant","cwd":"\#(cwd)","message":{"stop_reason":"tool_use","content":[]}}"#) == nil)
  #expect(Transcript.turnEvent(line: #"{"type":"assistant","message":{"stop_reason":"pause_turn","content":[]}}"#) == nil)
  #expect(Transcript.turnEvent(line: #"{"type":"assistant","message":{"stop_reason":null,"content":[]}}"#) == nil)
  #expect(Transcript.turnEvent(line: #"{"type":"user","message":{"content":[{"type":"tool_result","content":"x"}]}}"#) == nil)
}

@Test func turnEventIgnoresSidechainMetaAndGarbage() {
  #expect(Transcript.turnEvent(line: #"{"type":"assistant","isSidechain":true,"message":{"stop_reason":"end_turn","content":[]}}"#) == nil)
  #expect(Transcript.turnEvent(line: #"{"type":"user","isMeta":true,"message":{"content":"x"}}"#) == nil)
  #expect(Transcript.turnEvent(line: #"{"type":"attachment","attachment":{}}"#) == nil)
  #expect(Transcript.turnEvent(line: "garbage") == nil)
  #expect(Transcript.turnEvent(line: "") == nil)
}

@Test func turnEventWithoutCwdHasNilCwd() {
  #expect(Transcript.turnEvent(line: #"{"type":"user","message":{"content":"hi"}}"#) == TurnEvent(kind: .prompt, cwd: nil))
}
