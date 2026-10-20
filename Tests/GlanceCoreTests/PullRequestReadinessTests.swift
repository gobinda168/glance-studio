import Foundation
import Testing
@testable import GlanceCore

private func basePage() throws -> PullRequestPage.Page {
  try #require(PullRequestPage.parse(Data(viewOutput.utf8)))
}

@Test func theCanvasPullRequestIsBlockedByItsTwoThreads() throws {
  // Board 1: 14 of 14 checks, no conflicts, two blocking threads, one of two approvals.
  var page = try basePage()
  page.checks = .init(passed: 14)
  let readiness = PullRequestPage.readiness(page, blockingThreads: 2, requiredApprovals: 2)
  #expect(readiness.rows.map(\.title) == ["Checks", "No conflicts", "2 blocking threads", "Approvals"])
  #expect(readiness.rows.map(\.detail) == ["14 of 14 passing", "Up to date with main", "Unresolved review comments",
                                           "1 of 2 required"])
  #expect(readiness.rows.map(\.tone) == [.ok, .ok, .blocked, .pending])
  #expect(readiness.pill == .blocked(2))
  #expect(!readiness.canMerge) // GitHub says BLOCKED
  #expect(!readiness.asksFirst)
}

@Test func onlyGlancesThreadsLeftMeansMergeAsksFirst() throws {
  var page = try basePage()
  page.checks = .init(passed: 3)
  page.mergeState = .clean
  page.reviewDecision = .approved
  let readiness = PullRequestPage.readiness(page, blockingThreads: 1, requiredApprovals: nil)
  #expect(readiness.canMerge)
  #expect(readiness.asksFirst)
  #expect(readiness.pill == .blocked(1))
  let clear = PullRequestPage.readiness(page, blockingThreads: 0, requiredApprovals: nil)
  #expect(clear.pill == .ready && clear.canMerge && !clear.asksFirst)
  #expect(clear.rows.last?.detail == "1 approval")
}

@Test func conflictsFailingChecksAndRequestedChangesBlock() throws {
  var page = try basePage()
  page.mergeable = .conflicting
  page.latestReviews = [.init(author: "devon", state: .changesRequested, body: "", submittedAt: nil, id: "")]
  let readiness = PullRequestPage.readiness(page, blockingThreads: 0, requiredApprovals: nil)
  #expect(readiness.rows.first { $0.kind == .conflicts }?.tone == .blocked)
  #expect(readiness.rows.first { $0.kind == .approvals } == .init(kind: .approvals, tone: .blocked,
                                                                  title: "Changes requested", detail: "By devon"))
  // The fixture's checks: one failing. One conflict, one request for changes.
  #expect(readiness.pill == .blocked(3))
}

@Test func aBranchBehindItsBaseCanBeUpdated() throws {
  var page = try basePage()
  page.checks = .init(passed: 1)
  page.mergeState = .behind
  let readiness = PullRequestPage.readiness(page, blockingThreads: 0, requiredApprovals: nil)
  #expect(readiness.canUpdateBranch)
  #expect(readiness.rows.first { $0.kind == .conflicts }
    == .init(kind: .conflicts, tone: .pending, title: "Behind main", detail: "Update the branch to merge"))
  #expect(readiness.pill == .pending)
}

@Test func runningChecksAndAnUnknownMergeStateArePending() throws {
  var page = try basePage()
  page.checks = .init(passed: 2, pending: 1)
  page.mergeable = .unknown
  page.mergeState = .unknown
  let readiness = PullRequestPage.readiness(page, blockingThreads: 0, requiredApprovals: nil)
  #expect(readiness.rows.first?.detail == "1 of 3 running")
  #expect(readiness.rows[1].detail == "GitHub is still checking")
  #expect(readiness.pill == .pending)
  #expect(!readiness.canMerge)
}

@Test func draftsMergedAndClosedHaveTheirOwnPill() throws {
  var page = try basePage()
  page.isDraft = true
  #expect(PullRequestPage.readiness(page, blockingThreads: 0, requiredApprovals: nil).pill == .draft)
  page.isDraft = false
  page.state = .merged
  #expect(PullRequestPage.readiness(page, blockingThreads: 0, requiredApprovals: nil).pill == .merged)
  page.state = .closed
  let closed = PullRequestPage.readiness(page, blockingThreads: 0, requiredApprovals: nil)
  #expect(closed.pill == .closed && !closed.canMerge)
}

@Test func reviewersAreTheLatestReviewsThenWhoIsStillAsked() throws {
  var page = try basePage()
  #expect(PullRequestPage.reviewers(page) == [
    .init(login: "claude", state: .commented), .init(login: "mira-k", state: .approved),
    .init(login: "devon", state: .pending), .init(login: "Release", state: .pending),
  ])
  // Asked again after approving: pending again. The author's own comments don't make them a reviewer.
  page.requestedReviewers = ["mira-k"]
  page.latestReviews.append(.init(author: "gobinda168", state: .commented, body: "", submittedAt: nil, id: ""))
  #expect(PullRequestPage.reviewers(page) == [.init(login: "claude", state: .commented),
                                              .init(login: "mira-k", state: .pending)])
}
