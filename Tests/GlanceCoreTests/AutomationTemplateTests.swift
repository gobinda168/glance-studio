import Foundation
import Testing
@testable import GlanceCore

private let log = AutomationValue.decode(Data(#"{"failure": {"url": "https://ci/1", "lines": ["a", "b"]}}"#.utf8))!

private let context = AutomationTemplateContext(
  inputs: ["repo": .string("acme/app"), "pr": .number(412), "dry": .bool(false), "note": .null],
  trigger: .object(["title": .string("Fix it's broken"), "paths": .array([.string("/a.pdf")])]),
  steps: ["log": AutomationStepOutput(text: "raw", json: log), "fix": AutomationStepOutput(text: "Fixed.")],
  runDir: "/runs/1", automationDir: "/lib/fix-red-ci")

@Test func everyReferenceRenders() throws {
  #expect(try AutomationTemplate.render("{{inputs.repo}}#{{ inputs.pr }}", context) == "acme/app#412")
  #expect(try AutomationTemplate.render("[{{inputs.note}}] {{inputs.dry}}", context) == "[] false")
  #expect(try AutomationTemplate.render("{{trigger.title}}", context) == "Fix it's broken")
  #expect(try AutomationTemplate.render("{{trigger.paths.0}}", context) == "/a.pdf")
  #expect(try AutomationTemplate.render("{{steps.fix.text}}", context) == "Fixed.")
  #expect(try AutomationTemplate.render("{{steps.log.json.failure.url}}", context) == "https://ci/1")
  #expect(try AutomationTemplate.render("{{steps.log.json.failure.lines}}", context) == #"["a","b"]"#)
  #expect(try AutomationTemplate.render("{{steps.log.json.failure.lines.1}}", context) == "b")
  #expect(try AutomationTemplate.render("{{run.dir}} {{automation.dir}}", context) == "/runs/1 /lib/fix-red-ci")
  #expect(try AutomationTemplate.render("no braces } { here", context) == "no braces } { here")
}

@Test func referencesParseBothWays() throws {
  let references = try AutomationTemplate.references(in: "{{inputs.a}} {{trigger}} {{steps.x.json}} {{steps.y.text}}")
  #expect(references == [.input("a"), .trigger([]), .stepJSON("x", []), .stepText("y")])
  #expect(references.map(\.text) == ["inputs.a", "trigger", "steps.x.json", "steps.y.text"])
  #expect(references.compactMap(\.step) == ["x", "y"])
  #expect(AutomationReference("inputs.a.b") == nil)
  #expect(AutomationReference("steps.x") == nil)
  #expect(AutomationReference("steps..text") == nil)
}

@Test func badTemplatesThrowTypedErrors() {
  #expect(throws: AutomationTemplateError.unclosed) { try AutomationTemplate.render("{{inputs.repo", context) }
  #expect(throws: AutomationTemplateError.unknownReference("input.repo")) {
    try AutomationTemplate.render("{{input.repo}}", context)
  }
  #expect(throws: AutomationTemplateError.unknownReference("")) { try AutomationTemplate.render("{{ }}", context) }
  #expect(throws: AutomationTemplateError.missingInput("branch")) {
    try AutomationTemplate.render("{{inputs.branch}}", context)
  }
  #expect(throws: AutomationTemplateError.missingStep("later")) {
    try AutomationTemplate.render("{{steps.later.text}}", context)
  }
  #expect(throws: AutomationTemplateError.notJSON("fix")) {
    try AutomationTemplate.render("{{steps.fix.json.a}}", context)
  }
  #expect(throws: AutomationTemplateError.missingJSONPath(step: "log", path: "failure.sha")) {
    try AutomationTemplate.render("{{steps.log.json.failure.sha}}", context)
  }
  #expect(throws: AutomationTemplateError.missingTrigger("number")) {
    try AutomationTemplate.render("{{trigger.number}}", context)
  }
  var manual = context
  manual.trigger = nil
  #expect(throws: AutomationTemplateError.missingTrigger("")) { try AutomationTemplate.render("{{trigger}}", manual) }
  #expect(AutomationTemplateError.missingTrigger("").message == "this run has no trigger")
  #expect(AutomationTemplateError.missingJSONPath(step: "log", path: "a.b").message == "step `log`'s JSON has no `a.b`")
}

@Test func shellQuotingKeepsAValueOneWord() throws {
  let line = try AutomationTemplate.render("gh pr comment {{inputs.pr}} --title {{trigger.title}}", context,
                                           quoting: .shell)
  #expect(line == #"gh pr comment '412' --title 'Fix it'\''s broken'"#)
  #expect(AutomationTemplate.shellQuoted("a; rm -rf ~") == "'a; rm -rf ~'")
}

@Test func aDryRunStandsInForWhatOnlyARunKnows() throws {
  var dry = context
  dry.dryRun = true
  dry.trigger = nil
  dry.steps = ["log": AutomationStepOutput(text: "<run:log>")]
  #expect(try AutomationTemplate.render("{{steps.log.text}} {{steps.log.json.a.b}} {{trigger.title}}", dry)
    == "<run:log> <steps.log.json.a.b> <trigger.title>")
  #expect(throws: AutomationTemplateError.missingStep("fix")) { try AutomationTemplate.render("{{steps.fix.text}}", dry) }
  #expect(throws: AutomationTemplateError.missingInput("x")) { try AutomationTemplate.render("{{inputs.x}}", dry) }
}

@Test func anAutomationStepsInputsRenderInside() throws {
  let value = AutomationValue.object(["repo": .string("{{inputs.repo}}"), "n": .number(2),
                                      "list": .array([.string("{{inputs.pr}}")])])
  #expect(try AutomationTemplate.render(value, context)
    == .object(["repo": .string("acme/app"), "n": .number(2), "list": .array([.string("412")])]))
}

@Test func conditionsAreFalsyOnlyWhenEmptyFalseZeroOrNull() {
  for text in ["", "  ", "false", "FALSE", "0", "null", " false\n"] { #expect(!AutomationTemplate.isTruthy(text)) }
  for text in ["true", "1", "yes", "anything", "<claude:x>"] { #expect(AutomationTemplate.isTruthy(text)) }
}

private let manifest = AutomationManifest(id: "a", name: "A", inputs: [
  AutomationInput(name: "repo", required: true),
  AutomationInput(name: "pr", type: "number"),
  AutomationInput(name: "dry", type: "boolean", default: .bool(false)),
  AutomationInput(name: "mode", type: "enum", options: ["fast", "slow"]),
])

@Test func inputsResolveOverDefaultsWithTypes() {
  let resolved = manifest.resolveInputs(["repo": .string("acme/app"), "pr": .string("412"), "mode": .string("slow")])
  #expect(resolved.problems.isEmpty)
  #expect(resolved.values == ["repo": .string("acme/app"), "pr": .number(412), "dry": .bool(false),
                              "mode": .string("slow")])
  #expect(manifest.resolveInputs(["repo": .string("x")]).values["pr"] == .null)
}

@Test func badInputsAreProblems() {
  let resolved = manifest.resolveInputs(["pr": .string("abc"), "mode": .string("medium"), "branch": .string("x")])
  #expect(resolved.problems.map(\.description) == [
    "inputs.branch: there's no input `branch`",
    "inputs.repo: is required",
    "inputs.pr: `abc` isn't a number",
    "inputs.mode: `medium` isn't one of fast, slow",
  ])
}

@Test func checkUsesSamplesForMissingRequiredInputs() {
  let sampled = manifest.sampleInputs([:])
  #expect(sampled.problems.isEmpty)
  #expect(sampled.values["repo"] == .string("<repo>"))
  #expect(AutomationInput(name: "n", type: "number").sample == .number(1))
  #expect(AutomationInput(name: "m", type: "enum", options: ["x"]).sample == .string("x"))
}
