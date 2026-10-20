import Foundation
import Testing
@testable import GlanceCore

private let digestJSON = """
{
  "id": "digest", "version": 2, "name": "Morning digest",
  "inputs": {
    "tone": { "type": "enum", "options": ["short", "long"], "default": "short" },
    "notes": { "type": "text", "description": "  Anything to add  " },
    "count": { "type": "number", "required": true },
    "prNumber": { "type": "number" }
  },
  "triggers": [{ "kind": "manual" }],
  "steps": [{ "id": "a", "run": "echo hi" }]
}
"""

private func digest() -> AutomationManifest { AutomationManifest.parse(Data(digestJSON.utf8)).manifest! }

@Test func aFieldPerInputInTheManifestsOrder() {
  let fields = AutomationFormModel.fields(AutomationSample.manifest())
  #expect(fields.map(\.name) == ["repo", "pr", "dry", "repo_path"])
  #expect(fields.map(\.label) == ["Repo", "Pr", "Dry", "Repo path"])
  #expect(fields.map(\.control) == [.line, .number, .toggle, .path])
  #expect(fields[0].required && fields[0].help == "owner/name" && fields[0].initial == "")
  #expect(fields[2].initial == "false")
  #expect(fields[3].initial == "~/Code/app")
  let other = AutomationFormModel.fields(digest())
  #expect(other.map(\.control) == [.choice(["short", "long"]), .multiline, .number, .number])
  #expect(other[0].initial == "short")
  #expect(other[1].help == "Anything to add")
  #expect(other[3].label == "Pr number")
}

@Test func theFormSendsWhatWasTyped() {
  let fields = AutomationFormModel.fields(AutomationSample.manifest())
  #expect(AutomationFormModel.inputs(fields, values: ["repo": " acme/app ", "pr": "412", "dry": "true"])
    == ["repo": .string("acme/app"), "pr": .string("412"), "dry": .bool(true), "repo_path": .string("~/Code/app")])
  // An emptied field is left out, so its default (or "Required.") applies.
  #expect(AutomationFormModel.inputs(fields, values: ["repo": "  ", "repo_path": ""]) == ["dry": .bool(false)])
}

// Review focus: a wrong number or a missing required input says so under its field, and nothing runs.
@Test func formErrorsLandOnTheirFields() {
  let manifest = AutomationSample.manifest()
  #expect(AutomationFormModel.errors(manifest, inputs: ["pr": .string("12a")])
    == ["repo": "Required.", "pr": "`12a` isn't a number."])
  #expect(AutomationFormModel.errors(manifest, inputs: ["repo": .string("acme/app"), "pr": .string("412")]).isEmpty)
}

@Test func aRowSaysWhereTheAutomationStands() {
  let now = Date(timeIntervalSince1970: 1_760_000_000)
  let manifest = AutomationSample.manifest()
  var entry = AutomationEntry(id: "fix-red-ci", manifest: manifest, problems: [], approval: .approved)
  #expect(AutomationText.row(entry, live: nil, now: now) == AutomationRowStatus(tone: .neutral, text: "Never run"))
  entry.lastRun = RunRecord(id: "r", status: .failed, trigger: "manual", inputs: [:], version: 3,
                            startedAt: now.addingTimeInterval(-7200), endedAt: now, steps: [], parkedAt: nil)
  #expect(AutomationText.row(entry, live: nil, now: now) == AutomationRowStatus(tone: .failed, text: "Failed 2 h ago"))
  let ref = AutomationRunRef(automation: "fix-red-ci", run: "r2")
  let running = AutomationLiveRun(ref: ref, name: "Fix red CI", trigger: "manual", startedAt: now, step: "fix")
  #expect(AutomationText.row(entry, live: running, now: now)
    == AutomationRowStatus(tone: .running, text: "Running fix"))
  let parked = AutomationLiveRun(ref: ref, name: "Fix red CI", trigger: "manual", startedAt: now, step: "comment",
                                 parked: true)
  #expect(AutomationText.row(entry, live: parked, now: now)
    == AutomationRowStatus(tone: .waiting, text: "Waiting for you at comment"))
  entry.approval = .changed(["Adds command `curl`"])
  #expect(AutomationText.row(entry, live: nil, now: now)
    == AutomationRowStatus(tone: .waiting, text: "Changed: approve it again"))
  entry.problems = [AutomationProblem("steps[1].tools", "`Write` isn't in permissions.tools")]
  #expect(AutomationText.row(entry, live: nil, now: now)
    == AutomationRowStatus(tone: .failed, text: "Broken: steps[1].tools: `Write` isn't in permissions.tools"))
  let fresh = AutomationEntry(id: "fix-red-ci", manifest: manifest, problems: [])
  #expect(AutomationText.row(fresh, live: nil, now: now)
    == AutomationRowStatus(tone: .waiting, text: "Not approved yet"))
  var ranBefore = fresh
  ranBefore.lastRun = RunRecord(id: "r", status: .ok, trigger: "manual", inputs: [:], version: 3,
                                startedAt: now.addingTimeInterval(-7200), endedAt: now, steps: [], parkedAt: nil)
  #expect(AutomationText.row(ranBefore, live: nil, now: now)
    == AutomationRowStatus(tone: .waiting, text: "Not approved yet"))
}

@Test func needsYouLinesSayWhatToDo() {
  let ref = AutomationRunRef(automation: "fix-red-ci", run: "r")
  #expect(AutomationText.need(.parked(ref, step: "comment"), name: "Fix red CI")
    == AutomationNeedLine(title: "Fix red CI is waiting", detail: "Approve or skip comment", tone: .waiting))
  #expect(AutomationText.need(.approval(automation: "fix-red-ci", lines: ["Changes its triggers"]), name: "Fix red CI")
    == AutomationNeedLine(title: "Approve Fix red CI", detail: "Changes its triggers", tone: .waiting))
  #expect(AutomationText.need(.brokenWatcher(automation: "fix-red-ci", stderr: "boom\nauth failed\n\n"),
                              name: "Fix red CI")
    == AutomationNeedLine(title: "Fix red CI's watcher stopped", detail: "auth failed", tone: .failed))
  #expect(AutomationText.need(.brokenWatcher(automation: "fix-red-ci", stderr: ""), name: "Fix red CI").detail
    == "It crashed 5 times in 10 minutes.")
  #expect(AutomationText.need(.broken(automation: "x", problem: "automation.json: is missing"), name: "x")
    == AutomationNeedLine(title: "x is broken", detail: "automation.json: is missing", tone: .failed))
}

@Test func triggerGlyphsAndTimes() {
  #expect(AutomationText.glyphs(AutomationSample.manifest()) == [.eye, .clock, .folder, .bolt])
  #expect(AutomationText.glyphs(nil) == [])
  let now = Date(timeIntervalSince1970: 1_760_000_000)
  #expect(AutomationText.ago(now.addingTimeInterval(-30), now: now) == "just now")
  #expect(AutomationText.ago(now.addingTimeInterval(60), now: now) == "just now")
  #expect(AutomationText.ago(now.addingTimeInterval(-300), now: now) == "5 min ago")
  #expect(AutomationText.ago(now.addingTimeInterval(-10_800), now: now) == "3 h ago")
  #expect(AutomationText.ago(now.addingTimeInterval(-172_800), now: now) == "2 d ago")
}

@Test func theLibraryListsByNameAndSearchesLikeTheMCP() {
  let digestEntry = AutomationEntry(id: "digest", manifest: digest(), problems: [])
  let fix = AutomationEntry(id: "fix-red-ci", manifest: AutomationSample.manifest(), problems: [])
  let broken = AutomationEntry(id: "old-ci-thing", manifest: nil,
                               problems: [AutomationProblem("automation.json", "is missing")])
  #expect(AutomationText.library([broken, digestEntry, fix], query: "").map(\.id)
    == ["fix-red-ci", "digest", "old-ci-thing"])
  #expect(AutomationText.library([broken, digestEntry, fix], query: " ci ").map(\.id) == ["fix-red-ci", "old-ci-thing"])
  #expect(AutomationText.library([broken, digestEntry, fix], query: "digest").map(\.id) == ["digest"])
}
