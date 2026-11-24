import Foundation
import Testing
@testable import GlanceCore

@Test func aReadKnowsTheBaseEvenWithNothingToRaise() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glance-branch-\(UUID().uuidString)").path
  try FileManager.default.createDirectory(atPath: dir + "/origin", withIntermediateDirectories: true)
  func git(_ root: String, _ arguments: String...) { _ = GitRun.data(root, ["-c", "user.name=t", "-c", "user.email=t@t"] + arguments) }
  git(dir + "/origin", "init", "-q", "-b", "main")
  try "a\n".write(toFile: dir + "/origin/a.txt", atomically: true, encoding: .utf8)
  git(dir + "/origin", "add", ".")
  git(dir + "/origin", "commit", "-qm", "first")
  git(dir, "clone", "-q", dir + "/origin", dir + "/clone")
  let clone = dir + "/clone"
  #expect(BranchSummary.read(folder: clone) == BranchSummary.Reading(base: "main", summary: nil))
  git(clone, "switch", "-qc", "feat/x")
  try "b\n".write(toFile: clone + "/b.txt", atomically: true, encoding: .utf8)
  git(clone, "add", ".")
  git(clone, "commit", "-qm", "second")
  #expect(BranchSummary.read(folder: clone) == BranchSummary.Reading(
    base: "main", summary: BranchSummary.Summary(branch: "feat/x", base: "main", additions: 1, deletions: 0)))
}

@Test func theBaseComesFromOriginsHead() {
  #expect(BranchSummary.base(fromOriginHead: "origin/main\n") == "main")
  #expect(BranchSummary.base(fromOriginHead: "origin/release/1") == "release/1")
  #expect(BranchSummary.base(fromOriginHead: "") == nil)
  #expect(BranchSummary.base(fromOriginHead: "origin/") == nil)
}

@Test func theBarSumsTheBranchAgainstItsBase() {
  let numstat = "12\t3\ta.swift\0107\t8\tb.swift\0"
  let summary = BranchSummary.summary(branch: "claude/x", base: "main", numstat: numstat)
  #expect(summary == BranchSummary.Summary(branch: "claude/x", base: "main", additions: 119, deletions: 11))
}

@Test func theBarHidesOnTheBaseAndWithNothingChanged() {
  #expect(BranchSummary.summary(branch: "main", base: "main", numstat: "1\t0\ta\0") == nil)
  #expect(BranchSummary.summary(branch: "claude/x", base: "main", numstat: "") == nil)
}
