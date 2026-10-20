import Testing
@testable import GlanceCore

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
  #expect(summary?.sentence() == "claude/x is 119 lines added and 11 removed against main")
}

@Test func theBarHidesOnTheBaseAndWithNothingChanged() {
  #expect(BranchSummary.summary(branch: "main", base: "main", numstat: "1\t0\ta\0") == nil)
  #expect(BranchSummary.summary(branch: "claude/x", base: "main", numstat: "") == nil)
}
