import Testing
@testable import GlanceCore

@Test func promptsAndTheBranchComeFromUserLines() {
  let lines = [
    #"{"type":"user","gitBranch":"abc-123-login","message":{"role":"user","content":"Fix ABC-123 please"}}"#,
    #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"On it"}]}}"#,
    #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#,
    #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"now the tests"}]}}"#,
    #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
    "not json",
  ]
  let scan = TicketTranscript.scan(lines)
  #expect(scan.prompts == ["Fix ABC-123 please", "now the tests"])
  #expect(scan.branch == "abc-123-login")
}

@Test func headIsNotABranch() {
  #expect(TicketTranscript.scan([#"{"type":"user","gitBranch":"HEAD","message":{"content":"x"}}"#]).branch == nil)
}
