import Foundation
import Testing
@testable import GlanceCore

private func page() throws -> PullRequestPage.Page { try #require(PullRequestPage.parse(Data(viewOutput.utf8))) }

@Test func claudeReadsThePullRequestReadOnly() {
  let arguments = PullRequestClaude.readArguments()
  #expect(arguments.starts(with: ["-p", "--output-format", "json", "--no-session-persistence"]))
  #expect(arguments.contains("--strict-mcp-config"))
  let tools = arguments.firstIndex(of: "--tools").map { Array(arguments[($0 + 1)...($0 + 3)]) }
  #expect(tools == ["Read", "Grep", "Glob"])
  #expect(arguments.contains(#"{"disableAllHooks":true}"#))
  #expect(arguments.last == PullRequestClaude.readRules)
  #expect(PullRequestClaude.readRules.contains("Worth a look:"))
}

@Test func theReadPromptCarriesTheTitleBranchesCommitsAndDiff() throws {
  let prompt = PullRequestClaude.readPrompt(try page(), repository: "gobinda168/glance", diff: "diff --git a/x b/x\n+new")
  #expect(prompt.contains("Pull request #51 in gobinda168/glance: Release: build, sign, zip, appcast, DMG and publish"))
  #expect(prompt.contains("feat/release → main · 2 commits · +323 −15 in 19 files"))
  #expect(prompt.contains("- 57ee700 feat(release): release.sh skeleton"))
  #expect(prompt.contains("## What\n- builds both apps"))
  #expect(prompt.hasSuffix("diff --git a/x b/x\n+new"))
}

@Test func aHugeDiffIsCutAndTheCutIsSaid() throws {
  let diff = String(repeating: "+line\n", count: 20_000) // 120,000 characters
  let prompt = PullRequestClaude.readPrompt(try page(), repository: "gobinda168/glance", diff: diff, limit: 60_000)
  #expect(prompt.count < 61_500)
  #expect(prompt.hasSuffix("[The diff goes on for 60000 more characters: read the files for the rest.]"))
}

@Test func readsClaudesJSONResult() {
  let ok = #"{"type":"result","subtype":"success","is_error":false,"result":"  Adds the release script.  ","session_id":"s"}"#
  #expect(PullRequestClaude.result(Data(ok.utf8)) == .success("Adds the release script."))
  let failed = #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Credit balance is too low"}"#
  #expect(PullRequestClaude.result(Data(failed.utf8)) == .failure(.init(kind: .failed, message: "Credit balance is too low")))
  // Some versions stream lines before the result.
  let streamed = "{\"type\":\"system\"}\n" + ok + "\n"
  #expect(PullRequestClaude.result(Data(streamed.utf8)) == .success("Adds the release script."))
  #expect(PullRequestClaude.result(Data("".utf8)) == .failure(.init(kind: .failed, message: "Claude Code gave no answer.")))
  #expect(PullRequestClaude.Failure.notInstalled.kind == .notInstalled)
}

@Test func askingAboutAPullRequestGivesClaudeThePullRequestAndWhatWasAskedBefore() throws {
  let asked = PullRequestClaude.askPrompt(try page(), repository: "gobinda168/glance", diff: "+rollback()",
                                          question: " Is the rollback safe? ")
  #expect(asked.hasPrefix("Pull request #51 in gobinda168/glance: Release: build, sign, zip, appcast, DMG and publish"))
  #expect(asked.contains("Diff:\n+rollback()"))
  #expect(!asked.contains("Asked and answered before"))
  #expect(asked.hasSuffix("\n\nQuestion: Is the rollback safe?"))
  let followUp = PullRequestClaude.askPrompt(
    try page(), repository: "gobinda168/glance", diff: "",
    earlier: [.init(question: "Is the rollback safe?", answer: "Yes, `rollback()` runs first.")],
    question: "And on a retry?")
  #expect(followUp.contains("Asked and answered before:\nQ: Is the rollback safe?\nA: Yes, `rollback()` runs first."))
  #expect(followUp.hasSuffix("Question: And on a retry?"))
  let general = PullRequestClaude.askPrompt(try page(), repository: "gobinda168/glance", diff: "", question: "  ")
  #expect(general.hasSuffix("Question: What should I know before merging it?"))
  #expect(PullRequestClaude.askArguments().contains(PullRequestClaude.askRules))
  #expect(PullRequestClaude.askArguments().contains("--no-session-persistence"))
}

@Test func aRunWithNoAnswerSaysWhatClaudePrintedOnStderr() {
  let none = Data("".utf8)
  #expect(PullRequestClaude.result(none, errors: Data("warning: x\nInvalid API key · Please run /login\n\n".utf8))
    == .failure(.init(kind: .failed, message: "Claude Code stopped: Invalid API key · Please run /login")))
  #expect(PullRequestClaude.result(none, errors: none)
    == .failure(.init(kind: .failed, message: PullRequestClaude.noAnswer)))
  let ok = #"{"type":"result","result":"Fine.","is_error":false}"#
  #expect(PullRequestClaude.result(Data(ok.utf8), errors: Data("noise".utf8)) == .success("Fine."))
}
