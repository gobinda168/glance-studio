import Foundation
import Testing
@testable import GlanceCore

struct HookInputTests {
  @Test func parsesAPreToolUseHookInput() {
    let json = """
    {"session_id":"s1","cwd":"/r","hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"t1",
     "tool_input":{"command":"git commit -m x"},"transcript_path":"/x.jsonl"}
    """
    let input = HookInput.parse(Data(json.utf8))
    #expect(input == HookInput(sessionID: "s1", cwd: "/r", event: "PreToolUse", toolName: "Bash", toolUseID: "t1",
                               command: "git commit -m x"))
  }

  @Test func parsesAPromptAndRejectsNonHookJSON() {
    let prompt = HookInput.parse(Data(#"{"session_id":"s","cwd":"/r","hook_event_name":"UserPromptSubmit","prompt":"fix it"}"#.utf8))
    #expect(prompt?.prompt == "fix it")
    #expect(HookInput.parse(Data(#"{"cwd":"/r"}"#.utf8)) == nil)
    #expect(HookInput.parse(Data("not json".utf8)) == nil)
  }

  @Test func repoLocationFromRevParse() {
    let out = "/Users/me/app-fix\n/Users/me/app/.git\nfix/x\n"
    #expect(RepoLocation.parse(out, cwd: "/Users/me/app-fix/src")
      == RepoLocation(worktree: "/Users/me/app-fix", commonDir: "/Users/me/app/.git", branch: "fix/x"))
    // Detached HEAD has no branch; a relative common dir resolves against the cwd.
    #expect(RepoLocation.parse("/r\n.git\nHEAD\n", cwd: "/r")?.branch == nil)
    #expect(RepoLocation.parse("/r\n.git\nHEAD\n", cwd: "/r")?.commonDir == "/r/.git")
    // git failed (no commits yet, not a repository): nothing.
    #expect(RepoLocation.parse("", cwd: "/r") == nil)
  }
}
