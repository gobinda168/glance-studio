import Foundation
import Testing
@testable import GlanceCore

@Test func toolsAreAllowedExactlyOrByTheirBareName() {
  let permissions = AutomationPermissions(tools: ["Bash(git:*)", "Read"], mcp: ["mcp__slack", "mcp__gh__pr_view"])
  #expect(permissions.allows(tool: "Bash(git:*)"))
  #expect(!permissions.allows(tool: "Bash(rm:*)"))
  #expect(!permissions.allows(tool: "Bash"))
  #expect(permissions.allows(tool: "Read"))
  #expect(permissions.allows(tool: "Read(~/Code/**)"))
  #expect(permissions.allows(mcp: "mcp__slack__post_message"))
  #expect(permissions.allows(mcp: "mcp__gh__pr_view"))
  #expect(!permissions.allows(mcp: "mcp__gh__pr_merge"))
  #expect(!permissions.allows(mcp: "mcp__slackbot__x"))
}

@Test func stepsOutsideThePermissionsAreProblems() {
  var manifest = AutomationSample.manifest()
  #expect(manifest.permissions.problems(in: manifest).isEmpty)
  manifest.steps[1].tools = ["Edit", "Write"]
  manifest.steps[1].mcp = ["mcp__linear__save_issue"]
  #expect(manifest.permissions.problems(in: manifest).map(\.description) == [
    "steps[1].tools: `Write` isn't in permissions.tools",
    "steps[1].mcp: `mcp__linear__save_issue` isn't in permissions.mcp",
  ])
}

@Test func theApprovalHashFollowsPermissionsAndTriggersOnly() {
  let approved = AutomationSample.manifest()
  let hash = AutomationApproval.hash(approved)
  #expect(hash.count == 64)
  var stepsOnly = approved
  stepsOnly.version = 4
  stepsOnly.steps[0].timeout = 60
  stepsOnly.description = "Changed."
  #expect(AutomationApproval.hash(stepsOnly) == hash)
  #expect(AutomationApproval.keeps(approvedHash: hash, stepsOnly))
  var widened = approved
  widened.permissions.network = false
  #expect(AutomationApproval.hash(widened) != hash)
  #expect(!AutomationApproval.keeps(approvedHash: hash, widened))
  var retimed = approved
  retimed.triggers[2].cron = "0 8 * * 1-5"
  #expect(!AutomationApproval.keeps(approvedHash: hash, retimed))
}

@Test func aStepOutsideTheApprovedPermissionsLosesTheApproval() {
  let approved = AutomationSample.manifest()
  var edited = approved
  edited.steps[1].tools = ["Edit", "Write"]
  #expect(!AutomationApproval.keeps(approvedHash: AutomationApproval.hash(approved), edited))
}

@Test func theApprovalDiffReadsAsPlainLines() {
  let old = AutomationSample.manifest()
  var new = old
  new.permissions.commands = ["gh", "git", "curl"]
  new.permissions.network = false
  new.permissions.folders = []
  new.triggers.remove(at: 2)
  new.triggers.append(AutomationTrigger(kind: "schedule", cron: "0 8 * * *"))
  #expect(AutomationApproval.changes(from: old, to: new) == [
    "Adds command `curl`",
    "Removes command `jq`",
    "Removes folder `~/Code`",
    "Turns network off",
    "Adds trigger schedule 0 8 * * *",
    "Removes trigger schedule 0 9 * * 1-5",
  ])
  var refiltered = old
  refiltered.triggers[2].inputs = ["repo": .string("acme/web")]
  #expect(AutomationApproval.changes(from: old, to: refiltered) == ["Changes a trigger's inputs or filter"])
  #expect(AutomationApproval.changes(from: old, to: old).isEmpty)
}

@Test func theApprovalDiffKeepsTheTriggerLineBesideOtherChanges() {
  let old = AutomationSample.manifest()
  var new = old
  new.permissions.commands.append("curl")
  new.triggers[2].inputs = ["repo": .string("acme/web")]
  #expect(AutomationApproval.changes(from: old, to: new) == [
    "Adds command `curl`",
    "Changes a trigger's inputs or filter",
  ])
}

@Test func reorderedPermissionListsKeepTheHash() {
  let approved = AutomationSample.manifest()
  var reordered = approved
  reordered.permissions.commands.reverse()
  reordered.permissions.tools.reverse()
  reordered.permissions.mcp.reverse()
  reordered.permissions.folders.reverse()
  #expect(AutomationApproval.hash(reordered) == AutomationApproval.hash(approved))
  #expect(AutomationApproval.keeps(approvedHash: AutomationApproval.hash(approved), reordered))
}

@Test func aManifestThatCannotBeHashedIsNeverApproved() {
  var broken = AutomationSample.manifest()
  broken.triggers[2].inputs = ["n": .number(.nan)]
  let hash = AutomationApproval.hash(broken)
  #expect(hash != AutomationApproval.hash(broken))
  #expect(!AutomationApproval.keeps(approvedHash: hash, broken))
}

@Test func theSandboxProfileWritesOnlyWhereAllowed() {
  let profile = SandboxProfile.make(
    permissions: AutomationPermissions(folders: ["~/Code", "/tmp/out/", "~/My \"Notes\""], network: false),
    runDirectory: "/Users/me/Library/Application Support/Glance/Automations/.runs/a/1",
    stateDirectory: "/Users/me/Library/Application Support/Glance/Automations/state", home: "/Users/me")
  #expect(profile == """
  (version 1)
  (allow default)
  (deny file-write*)
  (allow file-write*
    (subpath "/Users/me/Library/Application Support/Glance/Automations/.runs/a/1")
    (subpath "/Users/me/Library/Application Support/Glance/Automations/state")
    (subpath "/private/tmp")
    (subpath "/private/var/folders")
    (subpath "/Users/me/Code")
    (subpath "/tmp/out")
    (subpath "/private/tmp/out")
    (subpath "/Users/me/My \\"Notes\\"")
    (literal "/dev/null")
    (literal "/dev/zero")
    (literal "/dev/tty")
    (literal "/dev/stdout")
    (literal "/dev/stderr")
    (literal "/dev/dtracehelper")
    (regex #"^/dev/fd/[0-9]+$")
    (regex #"^/dev/ttys[0-9]+$"))
  (deny network-outbound (remote ip "*:*"))
  (deny network-inbound (local ip "*:*"))

  """)
}

@Test func networkPermissionDropsTheNetworkDenial() {
  let profile = SandboxProfile.make(permissions: AutomationPermissions(network: true), runDirectory: "/r",
                                    stateDirectory: "/s", home: "/Users/me")
  #expect(!profile.contains("network"))
  #expect(profile.contains(#"(subpath "/r")"#))
}
