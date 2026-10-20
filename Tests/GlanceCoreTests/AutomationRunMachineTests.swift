import Foundation
import Testing
@testable import GlanceCore

private func machine(_ manifest: AutomationManifest = AutomationSample.manifest(), trusted: Bool = false,
                     inputs: [String: AutomationValue]? = nil) -> AutomationRunMachine {
  let resolved = inputs ?? manifest.resolveInputs(["repo": .string("acme/app"), "pr": .number(412)]).values
  return AutomationRunMachine(.init(
    manifest: manifest, inputs: resolved, fire: .manual, runDirectory: "/L/.runs/fix-red-ci/r1",
    automationDirectory: "/L/fix-red-ci", home: "/Users/me",
    texts: AutomationSample.prompts.merging(["steps/fetch-failure.sh": "#!/bin/bash\ngh run view"]) { $1 },
    trusted: trusted))
}

private let failure = #"{"failure": {"url": "https://ci/1"}}"#

private func plans(_ effects: [AutomationRunMachine.Effect]) -> [AutomationStepPlan] {
  effects.compactMap { if case .start(let plan) = $0 { plan } else { nil } }
}

private func logged(_ effects: [AutomationRunMachine.Effect]) -> [String] {
  effects.compactMap { if case .log(let event) = $0 { event.name } else { nil } }
}

@Test func thePipelineRunsScriptThenClaudeThenParksAtTheOutwardStep() throws {
  var run = machine()
  var effects = run.start()
  #expect(logged(effects) == ["run.start", "step.start"])
  let log = try #require(plans(effects).first)
  #expect(log.work == .shell("/bin/bash '/L/fix-red-ci/steps/fetch-failure.sh'"))
  #expect(log.cwd == "/L/.runs/fix-red-ci/r1")
  #expect(log.outputsJSON)
  #expect(log.environment["GLANCE_INPUTS"] == #"{"dry":false,"pr":412,"repo":"acme/app","repo_path":"~/Code/app"}"#)
  #expect(log.environment["GLANCE_STEPS"] == "{}")

  effects = run.finished("log", AutomationStepResult(status: .ok, text: failure))
  let fix = try #require(plans(effects).first)
  #expect(fix.cwd == "/Users/me/Code/app")
  guard case .claude(let prompt, let arguments) = fix.work else { Issue.record("\(fix.work)"); return }
  #expect(prompt == "Fix the failure in https://ci/1 for acme/app.")
  #expect(arguments.contains("--model") && arguments.contains("Bash,Edit"))
  #expect(fix.environment["GLANCE_STEPS"] == #"{"log":{"json":{"failure":{"url":"https://ci/1"}},"text":"{\"failure\": {\"url\": \"https://ci/1\"}}"}}"#)

  effects = run.finished("fix", AutomationStepResult(status: .ok, text: "Pushed a fix.", durationMs: 9000,
                                                     costUSD: 0.42))
  #expect(logged(effects) == ["step.end", "run.park"])
  #expect(run.status == .parked)
  guard case .park(let comment) = effects.last else { Issue.record("\(effects)"); return }
  #expect(comment.work == .shell("gh pr comment '412' -F -"))
  #expect(comment.stdin == "Pushed a fix.")
  #expect(run.current == "comment")
}

@Test func approveSkipAndTrustAtAParkedStep() throws {
  func parked() -> AutomationRunMachine {
    var run = machine()
    _ = run.start()
    _ = run.finished("log", AutomationStepResult(status: .ok, text: failure))
    _ = run.finished("fix", AutomationStepResult(status: .ok, text: "done"))
    return run
  }
  var approved = parked()
  var effects = approved.resume(.approve)
  #expect(logged(effects) == ["run.resume", "step.start"])
  #expect(plans(effects).map(\.step) == ["comment"])
  effects = approved.finished("comment", AutomationStepResult(status: .ok, text: ""))
  let digest = try #require(plans(effects).first)
  #expect(digest.work == .automation(id: "summarize-prs", inputs: ["repo": .string("acme/app")]))

  var skipped = parked()
  effects = skipped.resume(.skip)
  #expect(logged(effects) == ["run.resume", "step.end", "step.start"])
  #expect(effects.contains(.log(.stepEnd(step: "comment", status: .skipped, text: "skipped by you", json: nil,
                                         durationMs: 0, costUSD: nil))))
  #expect(plans(effects).map(\.step) == ["digest"])

  var trusted = parked()
  effects = trusted.resume(.trust)
  #expect(effects.contains(.trust))
  #expect(trusted.trusted)
  #expect(trusted.resume(.approve).isEmpty)  // not parked any more
}

@Test func aTrustedRunDoesntPark() {
  var run = machine(trusted: true)
  _ = run.start()
  _ = run.finished("log", AutomationStepResult(status: .ok, text: failure))
  let effects = run.finished("fix", AutomationStepResult(status: .ok, text: "done"))
  #expect(plans(effects).map(\.step) == ["comment"])
  #expect(run.status == .running)
}

@Test func theLastStepEndsTheRunOkWithItsOutput() {
  var run = machine(trusted: true)
  _ = run.start()
  _ = run.finished("log", AutomationStepResult(status: .ok, text: failure))
  _ = run.finished("fix", AutomationStepResult(status: .ok, text: "done"))
  _ = run.finished("comment", AutomationStepResult(status: .ok, text: "posted"))
  let effects = run.finished("digest", AutomationStepResult(status: .ok, text: "3 PRs", json: .number(3)))
  #expect(effects.suffix(2) == [.log(.runEnd(status: .ok)), .end(.ok)])
  #expect(run.lastOutput == AutomationStepOutput(text: "3 PRs", json: .number(3)))
  #expect(run.isFinished)
}

@Test func aFalsyIfSkipsAndAFailureEndsTheRun() {
  var manifest = AutomationSample.manifest()
  manifest.steps[0].condition = "{{inputs.dry}}"
  manifest.steps[0].outputs = nil
  manifest.steps[1].claude = nil
  manifest.steps[1].tools = nil
  manifest.steps[1].model = nil
  manifest.steps[1].run = "make test"
  var run = machine(manifest)
  var effects = run.start()
  #expect(effects.contains(.log(.stepEnd(step: "log", status: .skipped, text: #"skipped: `if` rendered "false""#,
                                         json: nil, durationMs: 0, costUSD: nil))))
  #expect(plans(effects).map(\.step) == ["fix"])
  effects = run.finished("fix", AutomationStepResult(status: .failed, text: "boom\nExited with status 2."))
  #expect(logged(effects) == ["step.end", "run.end"])
  #expect(run.status == .failed)
  #expect(run.failedStep == "fix")
  #expect(run.finished("fix", AutomationStepResult(status: .ok, text: "late")).isEmpty)
}

@Test func aStepThatPromisedJSONAndPrintedTextFails() {
  var run = machine()
  _ = run.start()
  let effects = run.finished("log", AutomationStepResult(status: .ok, text: "not json"))
  #expect(effects.contains(.log(.stepEnd(step: "log", status: .failed,
                                         text: #"Expected JSON ("outputs": "json"), got: not json"#, json: nil,
                                         durationMs: 0, costUSD: nil))))
  #expect(run.status == .failed)
}

@Test func aTemplateThatDoesntRenderFailsItsStepWithWhere() {
  var manifest = AutomationSample.manifest()
  manifest.steps[0].stdin = "{{trigger.repo}}"
  var run = machine(manifest)
  let effects = run.start()
  #expect(effects.contains(.log(.stepEnd(step: "log", status: .failed,
                                         text: "steps[0].stdin: the trigger has no `repo`", json: nil, durationMs: 0,
                                         costUSD: nil))))
  #expect(effects.last == .end(.failed))
}

@Test func cancelAndExpire() {
  var running = machine()
  _ = running.start()
  #expect(running.cancel().isEmpty)  // the step must be stopped first
  #expect(running.finished("log", AutomationStepResult(status: .cancelled, text: "")).suffix(2)
    == [.log(.runEnd(status: .cancelled)), .end(.cancelled)])
  var lateOk = machine()
  _ = lateOk.start()
  _ = lateOk.cancel()
  #expect(lateOk.finished("log", AutomationStepResult(status: .ok, text: failure)).last == .end(.cancelled))
  var parked = machine()
  _ = parked.start()
  _ = parked.finished("log", AutomationStepResult(status: .ok, text: failure))
  _ = parked.finished("fix", AutomationStepResult(status: .ok, text: "x"))
  var expiring = parked
  #expect(parked.cancel() == [.log(.runEnd(status: .cancelled)), .end(.cancelled)])
  #expect(expiring.expire() == [.log(.runEnd(status: .expired)), .end(.expired)])
  #expect(expiring.expire().isEmpty)
}

@Test func aTimeoutFailsTheRunWithItsText() {
  var run = machine()
  _ = run.start()
  let effects = run.finished("log", AutomationStepResult(status: .timedOut, text: "Timed out after 300 seconds.",
                                                         durationMs: 300_000))
  #expect(effects.first == .log(.stepEnd(step: "log", status: .failed, text: "Timed out after 300 seconds.",
                                         json: nil, durationMs: 300_000, costUSD: nil)))
  #expect(run.status == .failed)
}

@Test func theLogTheMachineWritesSummarizesBackToTheRun() {
  var run = machine(trusted: true)
  var events: [RunLogEvent] = []
  func keep(_ effects: [AutomationRunMachine.Effect]) {
    for case .log(let event) in effects { events.append(event) }
  }
  keep(run.start())
  keep(run.finished("log", AutomationStepResult(status: .ok, text: failure)))
  keep(run.finished("fix", AutomationStepResult(status: .ok, text: "done", costUSD: 0.25)))
  keep(run.finished("comment", AutomationStepResult(status: .failed, text: "403")))
  let start = Date(timeIntervalSince1970: 1_791_536_400)
  let lines = events.enumerated().map { RunLogLine(at: start.addingTimeInterval(Double($0.offset)), event: $0.element) }
  let record = RunLog.summarize(RunLog.decode(lines.map(RunLog.line).joined(separator: "\n")), id: "r1", live: false)
  #expect(record?.status == .failed)
  #expect(record?.steps.map(\.id) == ["log", "fix", "comment"])
  #expect(record?.costUSD == 0.25)
  #expect(record?.trigger == "manual")
}

@Test func logEventsReadAsOneLineEach() {
  #expect(RunLogEvent.runStart(trigger: "manual", payload: nil, inputs: ["who": .string("x")], version: 2).summary
    == #"run.start v2 manual {"who":"x"}"#)
  #expect(RunLogEvent.stepOutput(step: "greet", chunk: "a\nb\n").summary == "step.output greet: a⏎b⏎")
  #expect(RunLogEvent.stepEnd(step: "fix", status: .ok, text: "Pushed.", json: nil, durationMs: 5, costUSD: 0.042)
    .summary == "step.end fix ok $0.0420: Pushed.")
  #expect(RunLogEvent.stepEnd(step: "s", status: .skipped, text: "", json: nil, durationMs: 0, costUSD: nil).summary
    == "step.end s skipped")
  #expect(RunLogEvent.runResume(step: "c", decision: .trust).summary == "run.resume c trust")
  #expect(RunLogEvent.runEnd(status: .cancelled).summary == "run.end cancelled")
  #expect(RunLogEvent.stepOutput(step: "s", chunk: String(repeating: "x", count: 300)).summary.count
    == "step.output s: ".count + 201)
}

private func scriptLine(_ text: String) -> String? {
  var manifest = AutomationSample.manifest()
  manifest.steps[0].condition = nil
  var run = AutomationRunMachine(.init(
    manifest: manifest, inputs: manifest.resolveInputs(["repo": .string("acme/app"), "pr": .number(412)]).values,
    fire: .manual, runDirectory: "/L/.runs/x/r1", automationDirectory: "/L/x", home: "/Users/me",
    texts: AutomationSample.prompts.merging(["steps/fetch-failure.sh": text]) { $1 }, trusted: true))
  guard case .shell(let line) = plans(run.start()).first?.work else { return nil }
  return line
}

@Test func aScriptsFirstLineReadsRightWithCRLFAndBlankLines() {
  #expect(scriptLine("#!/usr/bin/env bash\r\necho hi\r\n") == "/usr/bin/env bash '/L/x/steps/fetch-failure.sh'")
  #expect(scriptLine("\n#!/usr/bin/env bash\necho hi") == "/bin/zsh '/L/x/steps/fetch-failure.sh'")
  #expect(scriptLine("#!/bin/bash") == "/bin/bash '/L/x/steps/fetch-failure.sh'")
  #expect(scriptLine("") == "/bin/zsh '/L/x/steps/fetch-failure.sh'")
}

@Test func theEnvironmentStaysSmallAndTheBigJSONGoesToFiles() throws {
  var run = machine(trusted: true)
  let first = try #require(plans(run.start()).first)
  #expect(first.environment["GLANCE_INPUTS_FILE"] == "/L/.runs/fix-red-ci/r1/inputs.json")
  #expect(first.environment["GLANCE_STEPS_FILE"] == "/L/.runs/fix-red-ci/r1/steps.json")
  #expect(first.files["/L/.runs/fix-red-ci/r1/steps.json"] == "{}")
  #expect(first.files["/L/.runs/fix-red-ci/r1/inputs.json"] == first.environment["GLANCE_INPUTS"])

  let big = String(repeating: "x", count: 600_000)
  let effects = run.finished("log", AutomationStepResult(status: .ok, text: #"{"failure": {"url": "https://ci/1"}, "blob": "\#(big)"}"#))
  let fix = try #require(plans(effects).first)
  #expect(fix.environment["GLANCE_STEPS"] == nil)
  #expect(fix.environment["GLANCE_INPUTS"] != nil)
  #expect(fix.environment.values.reduce(0) { $0 + $1.utf8.count } < 4_000)
  let steps = try #require(fix.files["/L/.runs/fix-red-ci/r1/steps.json"])
  #expect(steps.utf8.count > 1_200_000)  // text + json, both kept in the file
  #expect(steps.contains(big))
}

@Test func aCancelledRunStaysCancelledWhateverTheStepReports() {
  func cancelling() -> AutomationRunMachine {
    var run = machine()
    _ = run.start()
    _ = run.cancel()
    return run
  }
  var failedStep = cancelling()
  #expect(failedStep.finished("log", AutomationStepResult(status: .failed, text: "boom")).last == .end(.cancelled))
  #expect(failedStep.status == .cancelled)
  #expect(failedStep.failedStep == nil)
  var timedOut = cancelling()
  #expect(timedOut.finished("log", AutomationStepResult(status: .timedOut, text: "late")).last == .end(.cancelled))
  var notJSON = cancelling()  // "log" promised JSON
  #expect(notJSON.finished("log", AutomationStepResult(status: .ok, text: "not json")).last == .end(.cancelled))
  #expect(notJSON.failedStep == nil)
}
