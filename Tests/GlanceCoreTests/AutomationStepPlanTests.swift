import Foundation
import Testing
@testable import GlanceCore

@Test func scriptsRunWithTheirShebangOrByExtension() {
  #expect(AutomationStepCommand.scriptLine(path: "/L/a/steps/x.sh", firstLine: "#!/usr/bin/env bash")
    == "/usr/bin/env bash '/L/a/steps/x.sh'")
  #expect(AutomationStepCommand.scriptLine(path: "/L/a/steps/x.sh", firstLine: "#! /bin/zsh -f")
    == "/bin/zsh -f '/L/a/steps/x.sh'")
  #expect(AutomationStepCommand.scriptLine(path: "/L/a/x.py", firstLine: "import os") == "python3 '/L/a/x.py'")
  #expect(AutomationStepCommand.scriptLine(path: "/L/a/x.mjs", firstLine: nil) == "node '/L/a/x.mjs'")
  #expect(AutomationStepCommand.scriptLine(path: "/L/a/x.rb", firstLine: nil) == "ruby '/L/a/x.rb'")
  #expect(AutomationStepCommand.scriptLine(path: "/L/it's/x.sh", firstLine: "echo")
    == #"/bin/zsh '/L/it'\''s/x.sh'"#)
  #expect(AutomationStepCommand.sandboxed("echo hi", profile: "(version 1)")
    == ["/usr/bin/sandbox-exec", "-p", "(version 1)", "/bin/zsh", "-lc", "echo hi"])
}

@Test func claudeStepsGetOnlyTheirToolsAndNoMCPUnlessAsked() {
  let plain = AutomationStepCommand.claudeArguments(tools: ["Bash(git:*)", "Edit", "Bash(gh:*)"], mcp: [],
                                                    model: "sonnet")
  #expect(plain == ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--no-session-persistence", "--settings", #"{"disableAllHooks":true}"#,
                    "--tools", "Bash,Edit", "--allowedTools", "Bash(git:*),Edit,Bash(gh:*)", "--strict-mcp-config",
                    "--model", "sonnet"])
  let none = AutomationStepCommand.claudeArguments(tools: [], mcp: [], model: nil)
  #expect(none.suffix(3) == ["--tools", "", "--strict-mcp-config"])
  let slack = AutomationStepCommand.claudeArguments(tools: [], mcp: ["mcp__slack__post"], model: "")
  #expect(slack.suffix(4) == ["--tools", "", "--allowedTools", "mcp__slack__post"])
  #expect(AutomationStepCommand.builtInTools(["mcp__x__y", "Read", "Read", "Grep(*)"]) == ["Read", "Grep"])
}

@Test func outputStopsAtOneMegabyteWithANote() {
  var cap = AutomationOutputCap()
  #expect(cap.accept("hello") == "hello")
  let big = String(repeating: "é", count: 600_000)  // 1.2 MB in UTF-8
  let kept = cap.accept(big)
  #expect(kept?.hasSuffix(AutomationOutputCap.note) == true)
  #expect((kept?.utf8.count ?? 0) - AutomationOutputCap.note.utf8.count == 999_994)
  #expect(cap.truncated)
  #expect(cap.accept("more") == nil)
}

@Test func aScriptsExitBecomesItsResult() {
  let ok = AutomationStepResult.script(stdout: "hello\r\n", stderr: "", exitStatus: 0, cancelled: false,
                                       timedOut: false, timeout: 300, profile: "", durationMs: 12)
  #expect(ok == AutomationStepResult(status: .ok, text: "hello", durationMs: 12))
  let failed = AutomationStepResult.script(stdout: "partial\n", stderr: "gh: not found\n", exitStatus: 127,
                                           cancelled: false, timedOut: false, timeout: 300, profile: "P",
                                           durationMs: 5)
  #expect(failed.status == .failed)
  #expect(failed.text == "partial\ngh: not found\nExited with status 127.")
  let sandbox = AutomationStepResult.script(stdout: "", stderr: "sandbox-exec: invalid profile\n", exitStatus: 65,
                                            cancelled: false, timedOut: false, timeout: 300, profile: "(version 1)",
                                            durationMs: 1)
  #expect(sandbox.text.hasSuffix("Sandbox profile:\n(version 1)"))
  let timedOut = AutomationStepResult.script(stdout: "", stderr: "", exitStatus: 143, cancelled: false,
                                             timedOut: true, timeout: 5, profile: "", durationMs: 5000)
  #expect(timedOut == AutomationStepResult(status: .timedOut, text: "Timed out after 5 seconds.", durationMs: 5000))
  let cancelled = AutomationStepResult.script(stdout: "x", stderr: "", exitStatus: 143, cancelled: true,
                                              timedOut: true, timeout: 5, profile: "", durationMs: 1)
  #expect(cancelled.status == .cancelled)
  let noisy = (1...30).map { "line \($0)" }.joined(separator: "\n")
  #expect(AutomationStepResult.lastLines(noisy, count: 20).hasPrefix("line 11\n"))
}

@Test func theApprovalPreviewShowsTheCommandThenStdinCut() {
  let plan = AutomationStepPlan(step: "comment", work: .shell("gh pr comment '412' -F -"), cwd: "/tmp",
                                stdin: String(repeating: "x", count: 1000), outward: true)
  #expect(plan.preview.hasPrefix("gh pr comment '412' -F -\n\nstdin:\nxxx"))
  #expect(plan.preview.count == 601)
  let nested = AutomationStepPlan(step: "d", work: .automation(id: "digest", inputs: ["repo": .string("a/b")]),
                                  cwd: "/tmp")
  #expect(nested.preview == #"digest {"repo":"a/b"}"#)
}

@Test func aToolWithACommaIsDroppedNotSplitInTwo() {
  let arguments = AutomationStepCommand.claudeArguments(tools: ["Read", "Bash(git status,git diff)", "Edit"],
                                                        mcp: ["mcp__a__b,mcp__c__d"], model: nil)
  #expect(arguments.contains("--allowedTools"))
  #expect(arguments[arguments.firstIndex(of: "--allowedTools")! + 1] == "Read,Edit")
  #expect(arguments[arguments.firstIndex(of: "--tools")! + 1] == "Read,Edit")
  #expect(arguments.contains("--strict-mcp-config"))  // the only MCP entry was dropped
  #expect(AutomationStepCommand.builtInTools(["Bash(a,b)", "Read"]) == ["Read"])
}

@Test func anOutwardClaudeStepsPreviewNamesItsToolsAndModel() {
  let arguments = AutomationStepCommand.claudeArguments(tools: ["Bash(gh:*)", "Edit"], mcp: ["mcp__slack__post"],
                                                        model: "opus")
  let plan = AutomationStepPlan(step: "fix", work: .claude(prompt: "Fix it.", arguments: arguments), cwd: "/tmp",
                                outward: true)
  #expect(plan.preview == "Tools: Bash(gh:*),Edit,mcp__slack__post\nModel: opus\n\nFix it.")
  let bare = AutomationStepPlan(
    step: "fix", work: .claude(prompt: "Hi", arguments: AutomationStepCommand.claudeArguments(tools: [], mcp: [],
                                                                                              model: nil)),
    cwd: "/tmp")
  #expect(bare.preview == "Tools: none\n\nHi")
}
