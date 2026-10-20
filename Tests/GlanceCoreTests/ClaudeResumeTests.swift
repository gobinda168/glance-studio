import Testing
@testable import GlanceCore

private let session = "6f1c2d3e-4a5b-4c6d-8e7f-0123456789ab"

@Test func claudeRunningInATerminalResumesItsSession() {
  #expect(ClaudeResume.command(running: "claude", sessionID: session) == "claude --resume \(session)")
  #expect(ClaudeResume.command(running: "claude --resume abc", sessionID: session) == "claude --resume \(session)")
  #expect(ClaudeResume.command(running: "claude -c", sessionID: session) == "claude --resume \(session)")
  #expect(ClaudeResume.command(running: "FOO=1 claude --model opus", sessionID: session) != nil)
  #expect(ClaudeResume.command(running: "~/.local/bin/claude", sessionID: session) != nil)
}

@Test func otherCommandsAreNeverBroughtBack() {
  #expect(ClaudeResume.command(running: nil, sessionID: session) == nil)
  #expect(ClaudeResume.command(running: "npm run dev", sessionID: session) == nil)
  #expect(ClaudeResume.command(running: "git log claude", sessionID: session) == nil)
  #expect(ClaudeResume.command(running: "claude | tee log", sessionID: session) == nil)
  #expect(ClaudeResume.command(running: "claude; rm -rf ~", sessionID: session) == nil)
}

@Test func onlyARealSessionIDIsTyped() {
  #expect(ClaudeResume.command(running: "claude", sessionID: nil) == nil)
  #expect(ClaudeResume.command(running: "claude", sessionID: "x; rm -rf ~") == nil)
  #expect(ClaudeResume.command(running: "claude", sessionID: "") == nil)
}
