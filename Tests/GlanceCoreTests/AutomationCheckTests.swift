import Foundation
import Testing
@testable import GlanceCore

private let script = "#!/bin/zsh\ngh run view --log-failed | tail -50 | jq -R -s '{failure: {url: .}}'\n"

private func package(_ files: [String: String] = [:], manifest: Data = Data(AutomationSample.json.utf8))
  -> AutomationPackage {
  var all = ["README.md": "# Fix red CI", "steps/fetch-failure.sh": script,
             "steps/watch-ci.sh": "#!/usr/bin/env bash\necho '{}'\n"]
  all.merge(AutomationSample.prompts) { $1 }
  all.merge(files) { $1 }
  return AutomationPackage(folderName: "fix-red-ci", directory: "/lib/fix-red-ci", manifest: manifest, files: all)
}

private let library: [String: Set<String>] = ["fix-red-ci": ["summarize-prs"], "summarize-prs": []]

@Test func theDryRunRendersEveryStepInOrderWithStandIns() {
  let manifest = AutomationSample.manifest()
  let dry = manifest.dryRun(inputs: manifest.sampleInputs([:]).values, prompts: AutomationSample.prompts,
                            automationDirectory: "/lib/fix-red-ci")
  #expect(dry.problems.isEmpty)
  #expect(dry.steps.map(\.id) == ["log", "fix", "comment", "digest"])
  #expect(dry.steps[0].detail == "steps/fetch-failure.sh")
  #expect(dry.steps[1].detail == "Fix the failure in <steps.log.json.failure.url> for <repo>.")
  #expect(dry.steps[1].cwd == "~/Code/app")
  #expect(dry.steps[2].command == "gh pr comment '' -F -")
  #expect(dry.steps[2].stdin == "<claude:fix>")
  #expect(dry.steps[2].outward)
  #expect(dry.steps[3].detail == #"summarize-prs {"repo":"<repo>"}"#)
}

@Test func aFalsyIfSkipsItsStep() {
  var manifest = AutomationSample.manifest()
  manifest.steps[2].condition = "{{inputs.dry}}"
  let dry = manifest.dryRun(inputs: manifest.sampleInputs([:]).values, prompts: [:], automationDirectory: "/lib/a")
  #expect(dry.steps[2].skipped)
  #expect(dry.steps[2].detail == #"skipped: `if` rendered "false""#)
  #expect(dry.steps[3].skipped == false)
}

@Test func theSpecPackagePassesAndListsItsShellChecks() {
  let result = AutomationCheck.run(package(), library: library, inputs: ["pr": .string("412")])
  #expect(result.problems.isEmpty)
  #expect(result.dryRun?.steps.count == 4)
  #expect(result.shellChecks == [
    AutomationShellCheck(location: "steps/fetch-failure.sh", script: script, shell: "/bin/zsh"),
    AutomationShellCheck(location: "steps/watch-ci.sh", script: "#!/usr/bin/env bash\necho '{}'\n", shell: "/bin/bash"),
    AutomationShellCheck(location: "steps[2].run", script: "gh pr comment '412' -F -", shell: "/bin/zsh"),
  ])
}

@Test func validationProblemsStopBeforeTheDryRun() {
  let result = AutomationCheck.run(package(), library: [:], inputs: [:])
  #expect(result.problems.map(\.description) == [
    "steps[3].automation: there's no automation `summarize-prs` in the library",
  ])
  #expect(result.dryRun == nil)
  let broken = AutomationCheck.run(package(manifest: Data("{".utf8)), library: library, inputs: [:])
  #expect(broken.problems.count == 1)
  #expect(broken.shellChecks.isEmpty)
}

@Test func givenInputsAreTypeChecked() {
  let result = AutomationCheck.run(package(), library: library, inputs: ["pr": .string("abc"), "branch": .null])
  #expect(result.problems.map(\.description) == [
    "inputs.branch: there's no input `branch`", "inputs.pr: `abc` isn't a number",
  ])
}

// Review Focus: a script saved with Windows line endings is named plainly instead of failing at run time with
// "bad interpreter" (and isn't sent to the shell to fail a second time).
@Test func windowsLineEndingsAreAProblem() {
  let result = AutomationCheck.run(package(["steps/fetch-failure.sh": "#!/bin/zsh\r\necho hi\r\n"]),
                                   library: library, inputs: [:])
  #expect(result.problems.map(\.description) == [
    "steps/fetch-failure.sh: has Windows line endings (CRLF); save it with LF line endings",
  ])
  #expect(!result.shellChecks.map(\.location).contains("steps/fetch-failure.sh"))
}

@Test func theShebangPicksTheShell() {
  #expect(AutomationCheck.shell(for: "#!/bin/bash\necho") == "/bin/bash")
  #expect(AutomationCheck.shell(for: "#!/usr/bin/env bash\n") == "/bin/bash")
  #expect(AutomationCheck.shell(for: "#!/bin/sh\n") == "/bin/sh")
  #expect(AutomationCheck.shell(for: "#!/usr/bin/env zsh\n") == "/bin/zsh")
  #expect(AutomationCheck.shell(for: "echo hi\n") == "/bin/zsh")
}

@Test func shellComplaintsBecomeProblems() {
  let check = AutomationShellCheck(location: "steps/x.sh", script: "", shell: "/bin/zsh")
  #expect(AutomationCheck.shellProblem(check, output: "zsh:2: parse error near `fi'\n")
    == AutomationProblem("steps/x.sh", "line 2: parse error near `fi'"))
  #expect(AutomationCheck.shellProblem(check, output: "/bin/bash: -c: line 3: syntax error near unexpected token `fi'\n"
    + "/bin/bash: -c: line 3: `fi'\n") == AutomationProblem("steps/x.sh", "line 3: syntax error near unexpected token `fi'"))
  #expect(AutomationCheck.shellProblem(check, output: "zsh: parse error near `\\n'")
    == AutomationProblem("steps/x.sh", "parse error near `\\n'"))
  #expect(AutomationCheck.shellProblem(check, output: "") == AutomationProblem("steps/x.sh", "the shell couldn't parse it"))
}

@Test func theReportIsOkOrOneProblemPerLine() {
  #expect(AutomationCheck.report([]) == "ok")
  #expect(AutomationCheck.report([AutomationProblem("id", "a"), AutomationProblem("name", "b")]) == "id: a\nname: b")
}
