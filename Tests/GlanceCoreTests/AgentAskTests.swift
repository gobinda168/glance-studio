import Foundation
import Testing
@testable import GlanceCore

// Agents (spec 2026-10-10-agents-design.md): `"kind": "agent"` and ask steps.

private let agentJSON = #"""
{
  "id": "fix-red-ci",
  "kind": "agent",
  "name": "Fix red CI",
  "steps": [
    { "id": "investigate", "claude": "prompts/investigate.md", "tools": ["Read"], "outputs": "json" },
    { "id": "propose", "ask": { "question": "{{steps.investigate.json.question}}",
                                "body": "{{steps.investigate.json.why}}",
                                "choices": "{{steps.investigate.json.choices}}", "text": true } },
    { "id": "fix", "claude": "prompts/fix.md", "tools": ["Edit"] }
  ],
  "permissions": { "tools": ["Read", "Edit"] }
}
"""#

private let prompts = ["prompts/investigate.md": "Find why CI fails.", "prompts/fix.md": "Do: {{steps.propose.text}}"]

private func agent() throws -> AutomationManifest {
  try #require(AutomationManifest.parse(Data(agentJSON.utf8)).manifest)
}

private func context(_ manifest: AutomationManifest) -> AutomationValidationContext {
  AutomationValidationContext(folderName: manifest.id, files: Set(prompts.keys), prompts: prompts)
}

private func machine(_ manifest: AutomationManifest) -> AutomationRunMachine {
  AutomationRunMachine(.init(manifest: manifest, inputs: [:], fire: .manual, runDirectory: "/L/.runs/a/r1",
                             automationDirectory: "/L/a", home: "/Users/me", texts: prompts, trusted: false))
}

private let investigation = #"{"question": "Two ways to fix it. Which?", "why": "exp is in seconds now.", "choices": ["Fix our token code", "Pin jsonwebtoken"]}"#

@Test func anAgentReadsWithItsKindAndAskStep() throws {
  let parsed = AutomationManifest.parse(Data(agentJSON.utf8))
  #expect(parsed.problems.isEmpty)
  let manifest = try agent()
  #expect(manifest.isAgent)
  #expect(manifest.steps[1].isAsk)
  #expect(manifest.steps[1].ask?.choices == .template("{{steps.investigate.json.choices}}"))
  #expect(manifest.steps[1].ask?.allowsText == true)
  #expect(manifest.validate(context(manifest)).isEmpty)
  // It writes back the way it read.
  let again = try JSONDecoder().decode(AutomationManifest.self, from: try JSONEncoder().encode(manifest))
  #expect(again == manifest)
  #expect(AutomationManifest(id: "x", name: "X").isAgent == false)
}

@Test func askStepsAndAgentsAreValidated() throws {
  var manifest = try agent()
  manifest.kind = "robot"
  #expect(manifest.validate(context(manifest)).map(\.description) == ["kind: `robot` isn't a kind; use automation or agent"])

  manifest = try agent()
  manifest.steps = [manifest.steps[1]]
  manifest.steps[0].ask = AutomationAsk(question: "Which?", choices: .list(["a", "b"]))
  #expect(manifest.validate(context(manifest)).map(\.description) == ["steps: an agent needs at least one claude step"])

  manifest = try agent()
  manifest.steps[1].ask = AutomationAsk(question: " ", choices: .list(["a", "", "c", "d", "e", "f", "g"]))
  manifest.steps[1].timeout = 5
  #expect(manifest.validate(context(manifest)).map(\.description) == [
    "steps[1].ask.question: can't be empty", "steps[1].ask.choices: at most 6 choices",
    "steps[1].ask.choices: a choice can't be empty", "steps[1].timeout: ask steps don't take timeout",
  ])

  manifest.steps[1].timeout = nil
  manifest.steps[1].ask = AutomationAsk(question: "Which?")
  #expect(manifest.validate(context(manifest)).map(\.description)
    == [#"steps[1].ask: needs choices, or "text": true for a typed answer"#])

  manifest.steps[1].ask = AutomationAsk(question: "{{steps.fix.text}}", choices: .list(["a"]))
  #expect(manifest.validate(context(manifest)).map(\.description)
    == ["steps[1].ask.question: `{{steps.fix.text}}`: step `fix` runs after this one"])

  manifest.steps[1].run = "echo"
  #expect(manifest.validate(context(manifest)).first?.description == "steps[1]: has run and ask; a step does one thing")

  let unknown = agentJSON.replacingOccurrences(of: #""text": true"#, with: #""txt": true"#)
  #expect(AutomationManifest.parse(Data(unknown.utf8)).problems.map(\.description)
    == ["steps[1].ask.txt: isn't a field Glance knows (did you mean `text`?)"])
}

@Test func aLaterStepReadsTheAnswersJSON() throws {
  var manifest = try agent()
  manifest.steps[2].claude = "prompts/fix.md"
  let prompts = ["prompts/investigate.md": "x", "prompts/fix.md": "{{steps.propose.json.choice}}"]
  #expect(manifest.validate(AutomationValidationContext(folderName: manifest.id, files: Set(prompts.keys),
                                                        prompts: prompts)).isEmpty)
}

@Test func theDryRunAnswersWithTheFirstChoice() throws {
  var manifest = try agent()
  manifest.steps[1].ask = AutomationAsk(question: "Which?", choices: .list(["Fix it", "Pin it"]))
  let dry = manifest.dryRun(inputs: [:], prompts: prompts, automationDirectory: "/L/a")
  #expect(dry.problems.isEmpty)
  #expect(dry.steps.map(\.detail) == ["Find why CI fails.", "ask: Which? [Fix it | Pin it]", "Do: Fix it"])
  // Choices from an earlier step's JSON can only be judged in a real run.
  let real = try agent().dryRun(inputs: [:], prompts: prompts, automationDirectory: "/L/a")
  #expect(real.problems.isEmpty)
  #expect(real.steps[2].detail == "Do: <ask:propose>")
}

@Test func aRunAsksParksAndGoesOnWithTheAnswer() throws {
  var run = machine(try agent())
  _ = run.start()
  let effects = run.finished("investigate", AutomationStepResult(status: .ok, text: investigation))
  #expect(effects.compactMap { if case .log(let event) = $0 { event.name } else { nil } }
    == ["step.end", "step.start", "run.ask"])
  guard case .ask(let question) = effects.last else { Issue.record("\(effects)"); return }
  #expect(question == AutomationQuestion(step: "propose", question: "Two ways to fix it. Which?",
                                         body: "exp is in seconds now.",
                                         choices: ["Fix our token code", "Pin jsonwebtoken"], allowsText: true))
  #expect(run.status == .parked)
  #expect(run.question == question)
  #expect(run.parkedPlan == nil)
  #expect(run.current == "propose")

  let answer = try #require(AutomationAnswer.choice(0, of: question, via: .voice))
  let next = run.answer(answer)
  #expect(next.compactMap { if case .log(let event) = $0 { event.name } else { nil } }
    == ["run.answer", "step.end", "step.start"])
  #expect(run.status == .running)
  #expect(run.question == nil)
  guard case .start(let fix) = next.last, case .claude(let prompt, _) = fix.work else {
    Issue.record("\(next)")
    return
  }
  #expect(prompt == "Do: Fix our token code")
  #expect(run.outputs["propose"]?.json == .object(["answer": .string("Fix our token code"), "choice": .number(1),
                                                   "via": .string("voice")]))
  // A second answer does nothing.
  #expect(run.answer(answer).isEmpty)
}

@Test func choicesThatArentAListFailTheAskStep() throws {
  var run = machine(try agent())
  _ = run.start()
  let effects = run.finished("investigate", AutomationStepResult(
    status: .ok, text: #"{"question": "Q", "why": "W", "choices": "just one"}"#))
  #expect(run.status == .failed)
  #expect(run.failedStep == "propose")
  guard case .log(.stepEnd(_, .failed, let text, _, _, _)) = effects.dropLast(2).last else {
    Issue.record("\(effects)")
    return
  }
  #expect(text == #"steps[1].ask: choices should render to a JSON list of strings, got: "just one""#)
}

@Test func cancelOrExpireWhileAsking() throws {
  for expire in [false, true] {
    var run = machine(try agent())
    _ = run.start()
    _ = run.finished("investigate", AutomationStepResult(status: .ok, text: investigation))
    let effects = expire ? run.expire() : run.cancel()
    #expect(effects.last == .end(expire ? .expired : .cancelled))
    #expect(run.question == nil)
  }
}

@Test func typedAndSpokenWordsMatchAChoiceOrStandAlone() {
  let question = AutomationQuestion(step: "p", question: "Which?", choices: ["Fix it", "Pin it"], allowsText: false)
  #expect(AutomationAnswer.text(" pin IT ", for: question, via: .voice)
    == AutomationAnswer(answer: "Pin it", choice: 2, via: .voice))
  #expect(AutomationAnswer.text("something else", for: question, via: .text) == nil)
  var open = question
  open.allowsText = true
  #expect(AutomationAnswer.text("something else", for: open, via: .text)
    == AutomationAnswer(answer: "something else", via: .text))
  #expect(AutomationAnswer.choice(5, of: question, via: .click) == nil)
}

@Test func theAskAndTheAnswerAreLoggedAndSummarized() throws {
  var run = machine(try agent())
  var events: [RunLogEvent] = []
  func keep(_ effects: [AutomationRunMachine.Effect]) { for case .log(let event) in effects { events.append(event) } }
  keep(run.start())
  keep(run.finished("investigate", AutomationStepResult(status: .ok, text: investigation, costUSD: 0.06)))
  let start = Date(timeIntervalSince1970: 1_791_536_400)
  func record(live: Bool) -> RunRecord? {
    let lines = events.enumerated().map { RunLogLine(at: start.addingTimeInterval(Double($0.offset)), event: $0.element) }
    return RunLog.summarize(RunLog.decode(lines.map(RunLog.line).joined(separator: "\n")), id: "r1", live: live)
  }
  let waiting = try #require(record(live: true))
  #expect(waiting.status == .parked)
  #expect(waiting.parkedAt == "propose")
  #expect(waiting.question?.choices == ["Fix our token code", "Pin jsonwebtoken"])
  let rows = AutomationTimeline.steps(waiting, manifest: try agent())
  #expect(rows.map(\.id) == ["investigate", "propose", "fix"])
  #expect(rows.map(\.kind) == [.claude, .ask, .claude])
  #expect(rows[1].phase == .waiting)
  #expect(rows[1].line == "Waiting for you")
  #expect(rows[1].question?.question == "Two ways to fix it. Which?")

  keep(run.answer(AutomationAnswer(answer: "Pin jsonwebtoken", choice: 2, via: .click)))
  let answered = try #require(record(live: true))
  #expect(answered.status == .running)
  #expect(answered.question == nil)
  #expect(answered.steps[1].answer == AutomationAnswer(answer: "Pin jsonwebtoken", choice: 2, via: .click))
  let row = AutomationTimeline.steps(answered, manifest: try agent())[1]
  #expect(row.line == "Answered")
  #expect(row.text == "Pin jsonwebtoken")

  #expect(RunLogEvent.runAsk(AutomationQuestion(step: "p", question: "Which?", choices: ["a", "b"], allowsText: false))
    .summary == "run.ask p: Which? [a | b]")
  #expect(RunLogEvent.runAnswer(step: "p", answer: AutomationAnswer(answer: "a", choice: 1, via: .voice)).summary
    == "run.answer p voice: a")
}

@Test func aRunWaitingOnAQuestionIsAskingYouUnderNeedsYou() {
  let ref = AutomationRunRef(automation: "fix-red-ci", run: "r1")
  let question = AutomationQuestion(step: "propose", question: "Which fix?", choices: ["a"], allowsText: false)
  let live = AutomationLiveRun(ref: ref, name: "Fix red CI", trigger: "manual", startedAt: Date(), step: "propose",
                               parked: true, question: question)
  let needs = AutomationNeed.make([], live: [live])
  #expect(needs == [.question(ref, question)])
  #expect(AutomationText.need(needs[0], name: "Fix red CI")
    == AutomationNeedLine(title: "Fix red CI is asking you", detail: "Which fix?", tone: .waiting))
}
