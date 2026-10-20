import Foundation
import Testing
@testable import GlanceCore

@Test func aNewAutomationIsUnapprovedEnabledAndUntrusted() {
  let book = AutomationApprovalBook()
  let manifest = AutomationSample.manifest()
  #expect(book.status(of: manifest) == .never)
  #expect(book.record("fix-red-ci").enabled)
  #expect(!book.record("fix-red-ci").trusted)
  #expect(!book.isArmed(manifest, problems: []))
}

@Test func approvingArmsItAndAStepOnlyEditKeepsTheApproval() {
  var book = AutomationApprovalBook()
  var manifest = AutomationSample.manifest()
  book.approve(manifest, manifestText: AutomationSample.json)
  #expect(book.status(of: manifest) == .approved)
  #expect(book.record("fix-red-ci").approvedVersion == 3)
  #expect(book.isArmed(manifest, problems: []))
  #expect(!book.isArmed(manifest, problems: [AutomationProblem("id", "x")]))
  manifest.version = 4
  manifest.steps[2].run = "gh pr comment {{inputs.pr}} --body-file -"
  #expect(book.status(of: manifest) == .approved)
  book.setEnabled("fix-red-ci", false)
  #expect(!book.isArmed(manifest, problems: []))
}

@Test func aPermissionChangeNeedsApprovalAgainWithTheDiff() {
  var book = AutomationApprovalBook()
  book.approve(AutomationSample.manifest(), manifestText: AutomationSample.json)
  var manifest = AutomationSample.manifest()
  manifest.permissions.commands.append("curl")
  #expect(book.status(of: manifest) == .changed(["Adds command `curl`"]))
  // A step that leaves the approved tools also loses the approval.
  var stepped = AutomationSample.manifest()
  stepped.steps[1].tools = ["Write"]
  #expect(!book.status(of: stepped).isApproved)
}

// Controller ruling (A0 review): a hash change with no diff line of its own still says something.
@Test func aTriggerReorderSaysItChangesItsTriggers() {
  var book = AutomationApprovalBook()
  book.approve(AutomationSample.manifest(), manifestText: AutomationSample.json)
  var reordered = AutomationSample.manifest()
  reordered.triggers.swapAt(1, 2)
  #expect(book.status(of: reordered) == .changed(["Changes its triggers"]))
  var doubled = AutomationSample.manifest()
  doubled.triggers.append(doubled.triggers[4])
  #expect(book.status(of: doubled) == .changed(["Changes a trigger's inputs or filter"]))
}

@Test func anApprovalWithoutItsManifestTextStillSaysWhat() {
  let manifest = AutomationSample.manifest()
  let book = AutomationApprovalBook(records: [
    "fix-red-ci": AutomationApprovalRecord(approvedVersion: 1, approvedPermissionsHash: "old"),
  ])
  #expect(book.status(of: manifest) == .changed(["Changes its permissions or triggers"]))
}

@Test func theFileRoundTripsAndACorruptOneIsNil() {
  var book = AutomationApprovalBook()
  book.approve(AutomationSample.manifest(), manifestText: AutomationSample.json)
  book.setTrusted("fix-red-ci", true)
  book.setEnabled("other", false)
  let decoded = AutomationApprovalBook.decode(book.encoded())
  #expect(decoded == book)
  #expect(String(decoding: book.encoded(), as: UTF8.self).hasPrefix("{\n  \"fix-red-ci\" : {"))
  // The spec's shape, written by hand: missing fields take their defaults.
  let spec = #"{ "a": { "approvedVersion": 2, "approvedPermissionsHash": "h", "trusted": true } }"#
  #expect(AutomationApprovalBook.decode(Data(spec.utf8))?.record("a")
    == AutomationApprovalRecord(approvedVersion: 2, approvedPermissionsHash: "h", trusted: true, enabled: true))
  #expect(AutomationApprovalBook.decode(Data("{ \"a\": 3 }".utf8)) == nil)
  #expect(AutomationApprovalBook.decode(Data("not json".utf8)) == nil)
  book.remove("fix-red-ci")
  #expect(book.status(of: AutomationSample.manifest()) == .never)
}

// Controller ruling (A0 review): the sandbox stops file writes and direct IP connections only, so the words say that.
@Test func theSummarySaysWhatApprovingAllowsInPlainWords() {
  let lines = AutomationApproval.summary(AutomationSample.manifest())
  #expect(lines == [
    "Runs commands `gh`, `git`, `jq`",
    "Claude may use `Bash(git:*)`, `Edit`",
    "File writes limited to its run folder, Glance's automation state, temporary folders and `~/Code`",
    "Direct internet access",
    "Starts on watcher steps/watch-ci.sh every 2m; schedule 0 9 * * 1-5; files ~/Downloads (*.pdf); "
      + "event meeting.ended",
    "Asks before running `comment`",
  ])
  let quiet = AutomationManifest(id: "a", name: "A", steps: [AutomationStep(id: "s", run: "echo hi")])
  #expect(AutomationApproval.summary(quiet) == [
    "File writes limited to its run folder, Glance's automation state and temporary folders",
    "No direct internet access",
    "Starts only when you run it",
  ])
  for line in lines + AutomationApproval.summary(quiet) {
    #expect(!line.lowercased().contains("sandbox"))
    #expect(!line.lowercased().contains("no network"))
  }
}

@Test func needsYouListsParkedRunsBrokenThingsAndApprovals() {
  let manifest = AutomationSample.manifest()
  let ref = AutomationRunRef(automation: "fix-red-ci", run: "2026-10-09T09-00-00.000Z")
  let entries = [
    AutomationEntry(id: "fix-red-ci", manifest: manifest, problems: [], approval: .approved),
    AutomationEntry(id: "b-watch", manifest: manifest, problems: [], approval: .approved, brokenWatcher: "boom"),
    AutomationEntry(id: "c-broken", manifest: nil, problems: [AutomationProblem("automation.json", "isn't valid JSON")]),
    AutomationEntry(id: "d-changed", manifest: manifest, problems: [], approval: .changed(["Adds command `curl`"])),
    AutomationEntry(id: "e-off", manifest: manifest, problems: [], approval: .never, enabled: false),
    AutomationEntry(id: "f-new", manifest: manifest, problems: [], approval: .never),
  ]
  let live = [AutomationLiveRun(ref: ref, name: "Fix red CI", trigger: "manual", startedAt: Date(), step: "comment",
                                parked: true)]
  let needs = AutomationNeed.make(entries, live: live)
  #expect(needs.count == 5)
  #expect(needs[0] == .parked(ref, step: "comment"))
  #expect(needs[1] == .brokenWatcher(automation: "b-watch", stderr: "boom"))
  #expect(needs[2] == .broken(automation: "c-broken", problem: "automation.json: isn't valid JSON"))
  #expect(needs[3] == .approval(automation: "d-changed", lines: ["Adds command `curl`"]))
  #expect(needs[4] == .approval(automation: "f-new", lines: AutomationApproval.summary(manifest)))
  #expect(entries[0].armed && !entries[3].armed && !entries[4].armed)
  #expect(entries[2].brokenLine == "Broken: automation.json: isn't valid JSON")
}

@Test func triggerInputsRenderAgainstThePayloadUnderGivenOnes() {
  let manifest = AutomationSample.manifest()
  var trigger = AutomationTrigger(kind: "event", name: "pr.ci.failed")
  trigger.inputs = ["repo": .string("{{trigger.repo}}"), "pr": .string("{{trigger.number}}")]
  let fire = AutomationFire.trigger(trigger, payload: .object(["repo": .string("acme/app"), "number": .number(412)]))
  #expect(fire.summary == "event pr.ci.failed")
  let resolved = fire.inputs(for: manifest, given: [:])
  #expect(resolved.problems.isEmpty)
  #expect(resolved.values["repo"] == .string("acme/app"))
  #expect(resolved.values["pr"] == .number(412))
  #expect(fire.inputs(for: manifest, given: ["repo": .string("me/x")]).values["repo"] == .string("me/x"))
  let empty = AutomationFire.trigger(trigger, payload: .object([:]))
  #expect(empty.inputs(for: manifest, given: [:]).problems.map(\.description) == [
    "trigger.inputs.pr: the trigger has no `number`", "trigger.inputs.repo: the trigger has no `repo`",
    "inputs.repo: is required",
  ])
}

@Test func trustIsDroppedWhenADifferentPermissionSetIsApproved() {
  var book = AutomationApprovalBook()
  var manifest = AutomationSample.manifest()
  book.approve(manifest, manifestText: AutomationSample.json)
  book.setTrusted("fix-red-ci", true)
  // The same permissions approved again (a step-only edit): trust stays.
  manifest.version = 4
  manifest.steps[2].run = "gh pr comment {{inputs.pr}} --body-file -"
  book.approve(manifest, manifestText: AutomationSample.json)
  #expect(book.record("fix-red-ci").trusted)
  #expect(book.record("fix-red-ci").approvedVersion == 4)
  // New permissions: the user approves what they were shown now, trust was for the old ones.
  manifest.permissions.commands.append("curl")
  book.approve(manifest, manifestText: AutomationSample.json)
  #expect(!book.record("fix-red-ci").trusted)
  #expect(book.status(of: manifest) == .approved)
}
