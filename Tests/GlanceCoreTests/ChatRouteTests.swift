import Testing
@testable import GlanceCore

private func surface(_ pwd: String?, _ argv: [String], executable: String? = nil) -> ChatRoute.Surface {
  ChatRoute.Surface(pwd: pwd, executable: executable ?? argv.first, arguments: argv)
}

@Test func recognisesClaudeHoweverItIsInstalled() {
  #expect(ChatRoute.isClaude(executable: "/Users/me/.local/share/claude/versions/2.1.285", arguments: ["claude"]))
  #expect(ChatRoute.isClaude(executable: "/opt/homebrew/bin/claude", arguments: ["claude", "--continue"]))
  #expect(ChatRoute.isClaude(executable: "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe", arguments: ["claude.exe"]))
  #expect(ChatRoute.isClaude(executable: "/opt/homebrew/bin/node",
                             arguments: ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"]))
  #expect(!ChatRoute.isClaude(executable: "/bin/zsh", arguments: ["-zsh"]))
  #expect(!ChatRoute.isClaude(executable: "/usr/local/bin/claude-monitor", arguments: ["claude-monitor"]))
  #expect(!ChatRoute.isClaude(executable: nil, arguments: []))
}

@Test func theFirstSplitRunningClaudeInTheProjectGetsTheMessage() {
  let surfaces = [
    surface("/p", ["-zsh"], executable: "/bin/zsh"),
    surface("/other", ["claude"]),
    surface("/p/sub", ["claude"]),
    surface("/p/", ["claude"]),
    surface("/p", ["claude", "--continue"]),
  ]
  #expect(ChatRoute.decide(root: "/p", surfaces: surfaces, home: "/Users/me") == .terminal(index: 3))
}

@Test func noClaudeInTheProjectGoesHeadless() {
  let surfaces = [surface("/p", ["-zsh"], executable: "/bin/zsh"), surface(nil, ["claude"])]
  #expect(ChatRoute.decide(root: "/p", surfaces: surfaces, home: "/Users/me") == .headless)
  #expect(ChatRoute.decide(root: "/p", surfaces: [], home: "/Users/me") == .headless)
}

@Test func composerPayloadLabelsTheRoute() {
  let terminal = ChatComposer(context: "a.ts", route: .terminal(index: 0), working: false, notice: nil).payload
  #expect(terminal["route"] as? String == "terminal")
  #expect(terminal["routeLabel"] as? String == "Terminal")
  let headless = ChatComposer(context: nil, route: .headless, working: true, notice: "Claude stopped").payload
  #expect(headless["route"] as? String == "headless")
  #expect(headless["routeLabel"] as? String == "Headless · Auto")
  #expect(headless["working"] as? Bool == true)
  #expect(headless["notice"] as? String == "Claude stopped")
}

@Test func headlessArgumentsUseAutoModeAndTheSession() {
  #expect(ChatSession.arguments(sessionID: "abc", resume: false) ==
    ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
     "--permission-mode", "auto", "--session-id", "abc"])
  #expect(ChatSession.arguments(sessionID: "abc", resume: true).suffix(2) == ["--resume", "abc"])
}

@Test func resultLinesEndATurn() {
  #expect(ChatSession.outcome(line: #"{"type":"result","subtype":"success","is_error":false,"result":"DONE"}"#) == .done)
  #expect(ChatSession.outcome(line: #"{"type":"result","subtype":"error_during_execution","is_error":true}"#)
    == .failed("error_during_execution"))
  #expect(ChatSession.outcome(line: #"{"type":"result","is_error":true,"result":"No conversation found"}"#)
    == .failed("No conversation found"))
  #expect(ChatSession.outcome(line: #"{"type":"assistant","message":{"content":"result"}}"#) == nil)
  #expect(ChatSession.outcome(line: "not json") == nil)
}

@Test func aSavedSessionResumesOnlyWhileItsTranscriptExists() {
  let resumed = ChatSession.launchPlan(saved: "old", transcriptExists: true, newID: { "new" })
  #expect(resumed.id == "old" && resumed.resume)
  let gone = ChatSession.launchPlan(saved: "old", transcriptExists: false, newID: { "new" })
  #expect(gone.id == "new" && !gone.resume)
  let none = ChatSession.launchPlan(saved: nil, transcriptExists: false, newID: { "new" })
  #expect(none.id == "new" && !none.resume)
}

@Test func projectFolderNamesMatchClaudeCode() {
  #expect(ChatSession.projectFolder(cwd: "/Users/me/Code/glance") == "-Users-me-Code-glance")
  #expect(ChatSession.projectFolder(cwd: "/Users/me/my.app_v2") == "-Users-me-my-app-v2")
  #expect(ChatSession.projectFolder(cwd: "/private/tmp/claude-501/x") == "-private-tmp-claude-501-x")
}
