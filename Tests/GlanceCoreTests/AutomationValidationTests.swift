import Foundation
import Testing
@testable import GlanceCore

private let context = AutomationValidationContext(folderName: "fix-red-ci", files: AutomationSample.files,
                                                  prompts: AutomationSample.prompts,
                                                  automations: ["summarize-prs": []])

private func problems(_ edit: (inout AutomationManifest) -> Void,
                      context: AutomationValidationContext = context) -> [String] {
  var manifest = AutomationSample.manifest()
  edit(&manifest)
  return manifest.validate(context).map(\.description)
}

@Test func theSpecExampleIsValid() {
  #expect(AutomationSample.manifest().validate(context).isEmpty)
}

@Test func theIDMustBeASlugMatchingItsFolder() {
  #expect(problems { $0.id = "Fix_CI" } == ["id: `Fix_CI` must be 1–48 lowercase letters, digits or dashes"])
  #expect(problems { $0.id = "fix-ci" } == ["id: `fix-ci` must match its folder `fix-red-ci`"])
  #expect(problems { $0.id = String(repeating: "a", count: 49) }.count == 1)
  #expect(problems { $0.version = 0; $0.name = "  " } == ["version: must be 1 or more", "name: can't be empty"])
}

@Test func inputsNeedKnownTypesAndFittingDefaults() {
  #expect(problems { $0.inputs[1].type = "int" }
    == ["inputs.pr.type: `int` isn't a type; use string, number, boolean, enum, path, text"])
  #expect(problems { $0.inputs[1].type = "enum" } == ["inputs.pr.options: an enum needs its options"])
  #expect(problems { $0.inputs[0].options = ["a"] } == ["inputs.repo.options: only enum inputs have options"])
  #expect(problems { $0.inputs[1].default = .string("many") } == ["inputs.pr.default: `many` isn't a number"])
  #expect(problems { $0.inputs[1].name = "pr.number" }.first == "inputs.pr.number: names are letters, digits, _ and -")
}

@Test func triggersAreChecked() {
  #expect(problems { $0.triggers[0].kind = "cronjob" }
    == ["triggers[0].kind: `cronjob` isn't a trigger; use manual, schedule, files, event, watcher"])
  #expect(problems { $0.triggers[2].cron = "*/0 * * * *" } == ["triggers[2].cron: minute `*/0`: the step can't be 0"])
  #expect(problems { $0.triggers[2].cron = nil } == ["triggers[2].cron: a schedule needs a cron line"])
  #expect(problems { $0.triggers[2].inputs = ["repository": .string("x")] }
    == ["triggers[2].inputs.repository: there's no input `repository`"])
  #expect(problems { $0.triggers[3].path = "" } == ["triggers[3].path: a files trigger needs a path to watch"])
  #expect(problems { $0.triggers[4].name = "pr.merged" } == [
    "triggers[4].name: `pr.merged` isn't a Glance event; use meeting.ended, notice.new, ticket.moved, pr.ci.failed, "
      + "journal.closed, agent.message",
  ])
  #expect(problems { $0.triggers[4].filter = ["title": .string("Standup"), "room": .string("A")] }
    == ["triggers[4].filter.room: `meeting.ended` has no field `room`"])
  #expect(problems { $0.triggers[1].script = "steps/missing.sh" }
    == ["triggers[1].script: `steps/missing.sh` isn't in the package"])
  #expect(problems { $0.triggers[1].every = "1s" } == ["triggers[1].every: `1s` is too often; at least 10s"])
  #expect(problems { $0.triggers[1].every = "soon" }
    == ["triggers[1].every: `soon` isn't an interval; use 30s, 2m, 1h or 1d"])
}

@Test func stepsNeedUniqueIDsAndOneKind() {
  #expect(problems { $0.steps[2].id = "log" } == ["steps[2].id: `log` is used by steps[0] too"])
  #expect(problems { $0.steps[0].id = "fetch.log" }.first
    == "steps[0].id: `fetch.log` must be letters, digits, _ or - (no dots)")
  #expect(problems { $0.steps[0].claude = "prompts/fix.md" }
    == ["steps[0]: has run and claude; a step does one thing"])
  #expect(problems { $0.steps[0].run = nil } == ["steps[0]: needs one of run, claude or automation"])
  #expect(problems { $0.steps = [] } == ["steps: needs at least one step"])
}

@Test func filesAStepNamesMustBeInThePackage() {
  #expect(problems { $0.steps[0].run = "steps/fetch.sh" } == ["steps[0].run: `steps/fetch.sh` isn't in the package"])
  #expect(problems { $0.steps[1].claude = "prompts/other.md" }
    == ["steps[1].claude: `prompts/other.md` isn't in the package"])
}

@Test func claudeOnlyFieldsStayOnClaudeSteps() {
  #expect(problems { $0.steps[0].tools = ["Edit"]; $0.steps[0].model = "haiku" }
    == ["steps[0].tools: only Claude steps take tools", "steps[0].model: only Claude steps take model"])
  #expect(problems { $0.steps[0].inputs = ["a": .string("b")] }
    == ["steps[0].inputs: only automation steps take inputs"])
  #expect(problems { $0.steps[2].outputs = "yaml" } == ["steps[2].outputs: `yaml` isn't text or json"])
  #expect(problems { $0.steps[0].timeout = 0 } == ["steps[0].timeout: must be more than 0 seconds"])
}

// Review Focus: a step that reads a step after it is caught at save time, not as a run-time failure at 9 a.m.
@Test func templatesMayOnlyReadEarlierSteps() {
  #expect(problems { $0.steps[0].stdin = "{{steps.fix.text}}" }
    == ["steps[0].stdin: `{{steps.fix.text}}`: step `fix` runs after this one"])
  #expect(problems { $0.steps[2].stdin = "{{steps.comment.text}}" }
    == ["steps[2].stdin: `{{steps.comment.text}}`: step `comment` is this step"])
  #expect(problems { $0.steps[2].condition = "{{steps.lint.text}}" }
    == ["steps[2].if: `{{steps.lint.text}}`: step `lint` doesn't exist"])
  #expect(problems { $0.steps[2].stdin = "{{steps.fix.json.summary}}" }
    == [#"steps[2].stdin: `{{steps.fix.json.summary}}`: step `fix` outputs text; give it "outputs": "json""#])
}

@Test func templatesAreCheckedEverywhere() {
  #expect(problems { $0.steps[2].run = "gh pr comment {{inputs.number}} -F -" }
    == ["steps[2].run: `{{inputs.number}}`: there's no input `number`"])
  #expect(problems { $0.steps[3].inputs = ["repo": .array([.string("{{input.repo}}")])] }.first?
    .hasPrefix("steps[3].inputs.repo: `{{input.repo}}` isn't a reference Glance knows") == true)
  #expect(problems { $0.steps[1].cwd = "{{inputs.repo_path" } == ["steps[1].cwd: a `{{` has no closing `}}`"])
  var prompts = context
  prompts.prompts["prompts/fix.md"] = "Fix {{steps.comment.text}}"
  #expect(problems({ _ in }, context: prompts)
    == ["prompts/fix.md: `{{steps.comment.text}}`: step `comment` runs after this one"])
}

@Test func nestedAutomationsMustExistAndNotLoop() {
  #expect(problems { $0.steps[3].automation = "tidy-downloads" }
    == ["steps[3].automation: there's no automation `tidy-downloads` in the library"])
  #expect(problems { $0.steps[3].automation = "fix-red-ci" }
    == ["steps[3].automation: an automation can't run itself"])
  var looped = context
  looped.automations = ["summarize-prs": ["post-digest"], "post-digest": ["fix-red-ci"]]
  #expect(problems({ _ in }, context: looped)
    == ["steps[3].automation: runs in a loop: fix-red-ci → summarize-prs → post-digest → fix-red-ci"])
}

@Test func toolsAndMCPMustBeInsideThePermissions() {
  #expect(problems { $0.steps[1].tools = ["Edit", "Write"] } == ["steps[1].tools: `Write` isn't in permissions.tools"])
  #expect(problems { $0.permissions.mcp = ["slack"] } == ["permissions.mcp[0]: `slack` should start with mcp__"])
}

@Test func checkParsesThenValidates() {
  let data = AutomationSample.edited {
    $0["colour"] = "red"
    $0["id"] = "wrong"
  }
  let checked = AutomationManifest.check(data, context)
  #expect(checked.manifest?.id == "wrong")
  #expect(checked.problems.map(\.description) == [
    "colour: isn't a field Glance knows", "id: `wrong` must match its folder `fix-red-ci`",
  ])
  let broken = AutomationManifest.check(Data("nope".utf8), context)
  #expect(broken.manifest == nil)
  #expect(broken.problems.count == 1)
}

// Controller rulings: an empty inline command is a problem, and a script path can't leave the package.
@Test func commandsAreNotEmptyAndScriptsStayInsideThePackage() {
  #expect(problems { $0.steps[2].run = "" } == ["steps[2].run: can't be empty"])
  #expect(problems { $0.steps[2].run = " \n " } == ["steps[2].run: can't be empty"])
  #expect(problems { $0.steps[0].run = "../steps/fetch-failure.sh" } == ["steps[0].run: must stay inside the package"])
  #expect(problems { $0.steps[0].run = "steps/../../fetch.sh" } == ["steps[0].run: must stay inside the package"])
  #expect(problems { $0.steps[0].run = ".//etc/fetch.sh" } == ["steps[0].run: must stay inside the package"])
  #expect(problems { $0.steps[0].run = "steps/a..b.sh" } == ["steps[0].run: `steps/a..b.sh` isn't in the package"])
  #expect(problems { $0.triggers[1].script = "../watch-ci.sh" } == ["triggers[1].script: must stay inside the package"])
  #expect(problems { $0.triggers[1].script = "/etc/watch-ci.sh" }
    == ["triggers[1].script: must stay inside the package"])
}
