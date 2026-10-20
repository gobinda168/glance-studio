import Foundation
import Testing
@testable import GlanceCore

/// The spec's example package (2026-10-09-automations-design.md), shared by the Automation*Tests files.
enum AutomationSample {
  static let json = """
  {
    "id": "fix-red-ci",
    "version": 3,
    "name": "Fix red CI",
    "description": "When a PR's checks fail, read the failing log, push a fix, comment the result.",
    "tags": ["github", "ci", "pr"],
    "inputs": {
      "repo": { "type": "string", "required": true, "description": "owner/name" },
      "pr": { "type": "number" },
      "dry": { "type": "boolean", "default": false },
      "repo_path": { "type": "path", "default": "~/Code/app" }
    },
    "triggers": [
      { "kind": "manual" },
      { "kind": "watcher", "script": "steps/watch-ci.sh", "every": "2m" },
      { "kind": "schedule", "cron": "0 9 * * 1-5", "inputs": { "repo": "acme/app" } },
      { "kind": "files", "path": "~/Downloads", "glob": "*.pdf" },
      { "kind": "event", "name": "meeting.ended" }
    ],
    "steps": [
      { "id": "log", "run": "steps/fetch-failure.sh", "outputs": "json" },
      { "id": "fix", "claude": "prompts/fix.md", "tools": ["Bash(git:*)", "Edit"], "cwd": "{{inputs.repo_path}}",
        "model": "sonnet" },
      { "id": "comment", "run": "gh pr comment {{inputs.pr}} -F -", "stdin": "{{steps.fix.text}}", "outward": true },
      { "id": "digest", "automation": "summarize-prs", "inputs": { "repo": "{{inputs.repo}}" } }
    ],
    "permissions": {
      "commands": ["gh", "git", "jq"],
      "tools": ["Bash(git:*)", "Edit"],
      "mcp": [],
      "folders": ["~/Code"],
      "network": true
    }
  }
  """

  static let files: Set<String> = ["automation.json", "README.md", "steps/fetch-failure.sh", "steps/watch-ci.sh",
                                   "prompts/fix.md"]
  static let prompts = ["prompts/fix.md": "Fix the failure in {{steps.log.json.failure.url}} for {{inputs.repo}}."]

  static func manifest() -> AutomationManifest { AutomationManifest.parse(Data(json.utf8)).manifest! }

  /// The example with one edit to its JSON tree.
  static func edited(_ edit: (inout [String: Any]) -> Void) -> Data {
    var object = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    edit(&object)
    return try! JSONSerialization.data(withJSONObject: object)
  }
}

@Test func theSpecExampleDecodes() {
  let parsed = AutomationManifest.parse(Data(AutomationSample.json.utf8))
  #expect(parsed.problems.isEmpty)
  let manifest = parsed.manifest!
  #expect(manifest.id == "fix-red-ci")
  #expect(manifest.version == 3)
  #expect(manifest.tags == ["github", "ci", "pr"])
  #expect(manifest.inputs.map(\.name) == ["repo", "pr", "dry", "repo_path"])
  #expect(manifest.input("repo")?.required == true)
  #expect(manifest.input("dry")?.default == .bool(false))
  #expect(manifest.input("pr")?.kind == .number)
  #expect(manifest.triggers.map(\.typed) == [.manual, .watcher, .schedule, .files, .event])
  #expect(manifest.triggers[2].inputs == ["repo": .string("acme/app")])
  #expect(manifest.steps.map(\.kind) == [
    .script("steps/fetch-failure.sh"), .claude("prompts/fix.md"), .command("gh pr comment {{inputs.pr}} -F -"),
    .automation("summarize-prs"),
  ])
  #expect(manifest.steps[0].outputsJSON)
  #expect(manifest.steps[2].isOutward)
  #expect(manifest.steps[1].timeoutSeconds == 300)
  #expect(manifest.permissions.network)
  #expect(manifest.callees == ["summarize-prs"])
}

// JSONEncoder doesn't keep the inputs' order (only parsing a written file does), so compare them by name.
@Test func aManifestRoundTrips() throws {
  var manifest = AutomationSample.manifest()
  var parsed = AutomationManifest.parse(try JSONEncoder().encode(manifest))
  #expect(parsed.problems.isEmpty)
  manifest.inputs.sort { $0.name < $1.name }
  parsed.manifest?.inputs.sort { $0.name < $1.name }
  #expect(parsed.manifest == manifest)
}

@Test func missingOptionalPartsGetDefaults() {
  let parsed = AutomationManifest.parse(Data(#"{"id": "tiny", "name": "Tiny"}"#.utf8))
  #expect(parsed.problems.isEmpty)
  #expect(parsed.manifest?.version == 1)
  #expect(parsed.manifest?.steps.isEmpty == true)
  #expect(parsed.manifest?.permissions == AutomationPermissions())
}

@Test func runNamesAScriptOnlyWhenItLooksLikeOne() {
  #expect(AutomationStep.scriptPath("steps/fetch.sh") == "steps/fetch.sh")
  #expect(AutomationStep.scriptPath("./steps/fetch.sh") == "steps/fetch.sh")
  #expect(AutomationStep.scriptPath("tidy.py") == "tidy.py")
  #expect(AutomationStep.scriptPath("jq") == nil)
  #expect(AutomationStep.scriptPath("jq .items") == nil)
  #expect(AutomationStep.scriptPath("/usr/bin/true") == nil)
  #expect(AutomationStep.scriptPath("steps/{{inputs.name}}.sh") == nil)
  #expect(AutomationStep(id: "a", run: "x.sh", claude: "p.md").kind == nil)
  #expect(AutomationStep(id: "a").kind == nil)
}

@Test func aWrongTypeNamesItsPath() {
  let parsed = AutomationManifest.parse(AutomationSample.edited { $0["version"] = "3" })
  #expect(parsed.manifest == nil)
  #expect(parsed.problems.first == AutomationProblem("version", "should be a whole number"))
  let step = AutomationManifest.parse(AutomationSample.edited {
    var steps = $0["steps"] as! [[String: Any]]
    steps[2]["outward"] = "yes"
    $0["steps"] = steps
  })
  #expect(step.problems.first == AutomationProblem("steps[2].outward", "should be true or false"))
  let missing = AutomationManifest.parse(Data(#"{"id": "tiny"}"#.utf8))
  #expect(missing.problems == [AutomationProblem("name", "is required")])
}

@Test func unknownFieldsAreReportedWithAGuess() {
  let parsed = AutomationManifest.parse(AutomationSample.edited {
    var inputs = $0["inputs"] as! [String: Any]
    inputs["repo"] = ["type": "string", "requried": true]
    $0["inputs"] = inputs
    var steps = $0["steps"] as! [[String: Any]]
    steps[0]["shell"] = "zsh"
    $0["steps"] = steps
    $0["owner"] = "me"
  })
  #expect(parsed.manifest != nil)
  #expect(parsed.problems.map(\.description) == [
    "owner: isn't a field Glance knows",
    "inputs.repo.requried: isn't a field Glance knows (did you mean `required`?)",
    "steps[0].shell: isn't a field Glance knows",
  ])
}

// Review Focus: hand edits. Foundation's decoder takes a trailing comma, so it loads; a comment or a missing quote is
// one clear problem with Foundation's line and column, never a crash or silence.
@Test func handEditedJSONLoadsOrSaysWhereItBroke() {
  let trailing = AutomationManifest.parse(Data(#"{"id": "tiny", "name": "Tiny",}"#.utf8))
  #expect(trailing.problems.isEmpty)
  #expect(trailing.manifest?.name == "Tiny")
  let commented = AutomationManifest.parse(Data("{\n  \"id\": \"tiny\", // mine\n  \"name\": \"Tiny\"\n}".utf8))
  #expect(commented.manifest == nil)
  #expect(commented.problems.count == 1)
  #expect(commented.problems.first?.path == "automation.json")
  #expect(commented.problems.first?.message.hasPrefix("isn't valid JSON (") == true)
  #expect(commented.problems.first?.message.contains("line 2") == true)
  #expect(AutomationManifest.parse(Data("[1]".utf8)).problems == [
    AutomationProblem("automation.json", "must be a JSON object"),
  ])
}

@Test func valuesReadAsTemplateText() {
  #expect(AutomationValue.number(42).text == "42")
  #expect(AutomationValue.number(1.5).text == "1.5")
  #expect(AutomationValue.bool(true).text == "true")
  #expect(AutomationValue.null.text == "")
  #expect(AutomationValue.object(["b": .number(1), "a": .string("x/y")]).text == #"{"a":"x/y","b":1}"#)
  let tree = AutomationValue.decode(Data(#"{"items": [{"title": "Fix"}]}"#.utf8))!
  #expect(tree.value(at: ["items", "0", "title"]) == .string("Fix"))
  #expect(tree.value(at: ["items", "1", "title"]) == nil)
  #expect(tree.value(at: []) == tree)
}

@Test func triggersSummarizeInOneLine() {
  let triggers = AutomationSample.manifest().triggers.map(\.summary)
  #expect(triggers == ["manual", "watcher steps/watch-ci.sh every 2m", "schedule 0 9 * * 1-5",
                       "files ~/Downloads (*.pdf)", "event meeting.ended"])
}
