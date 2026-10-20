import Foundation
import Testing
@testable import GlanceCore

/// `gh pr view 51 --json …`, shaped as gh 2.101 prints it.
let viewOutput = """
{
  "number": 51, "title": "Release: build, sign, zip, appcast, DMG and publish",
  "body": "## What\\n- builds both apps", "state": "OPEN", "isDraft": false,
  "author": {"id": "MDQ6", "is_bot": false, "login": "gobinda168", "name": "Gobinda Das"},
  "createdAt": "2026-10-05T09:00:00Z", "headRefName": "feat/release",
  "headRefOid": "81380ed0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6", "baseRefName": "main",
  "additions": 323, "deletions": 15, "changedFiles": 19,
  "commits": [
    {"oid": "57ee700aa1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6", "messageHeadline": "feat(release): release.sh skeleton",
     "authoredDate": "2026-10-05T08:00:00Z", "committedDate": "2026-10-05T08:00:00Z",
     "authors": [{"login": "gobinda168", "name": "Gobinda Das", "email": "g@example.com", "id": "1"}]},
    {"oid": "81380ed0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6", "messageHeadline": "feat(release): build, sign, zip, appcast",
     "authoredDate": "2026-10-05T08:30:00Z", "committedDate": "2026-10-05T08:31:00Z",
     "authors": [{"login": "", "name": "Claude", "email": "noreply@anthropic.com", "id": ""}]}
  ],
  "reviews": [
    {"id": "PRR_1", "author": {"login": "claude"}, "authorAssociation": "NONE", "body": "Two blocking issues.",
     "submittedAt": "2026-10-06T10:00:00Z", "state": "COMMENTED", "commit": {"oid": "81380ed"}},
    {"id": "PRR_2", "author": {"login": "mira-k"}, "authorAssociation": "MEMBER", "body": "",
     "submittedAt": "2026-10-06T14:00:00Z", "state": "APPROVED", "commit": {"oid": "81380ed"}},
    {"id": "PRR_3", "author": {"login": "gobinda168"}, "body": "", "submittedAt": null, "state": "PENDING",
     "commit": {"oid": ""}}
  ],
  "latestReviews": [
    {"id": "", "author": {"login": "claude"}, "body": "Two blocking issues.", "submittedAt": "2026-10-06T10:00:00Z",
     "state": "COMMENTED", "commit": {"oid": ""}},
    {"id": "", "author": {"login": "mira-k"}, "body": "", "submittedAt": "2026-10-06T14:00:00Z", "state": "APPROVED",
     "commit": {"oid": ""}}
  ],
  "comments": [
    {"id": "IC_1", "author": {"login": "devon"}, "authorAssociation": "MEMBER", "body": "Looks close.",
     "createdAt": "2026-10-06T12:00:00Z", "url": "https://github.com/gobinda168/glance/pull/51#issuecomment-1",
     "viewerDidAuthor": false}
  ],
  "reviewRequests": [{"__typename": "User", "login": "devon"}, {"__typename": "Team", "name": "Release", "slug": "release"}],
  "statusCheckRollup": [
    {"__typename": "CheckRun", "name": "swift test", "status": "COMPLETED", "conclusion": "SUCCESS"},
    {"__typename": "CheckRun", "name": "lint", "status": "COMPLETED", "conclusion": "SKIPPED"},
    {"__typename": "CheckRun", "name": "sign", "status": "IN_PROGRESS", "conclusion": ""},
    {"__typename": "StatusContext", "context": "ci/legacy", "state": "FAILURE"}
  ],
  "mergeable": "MERGEABLE", "mergeStateStatus": "BLOCKED", "reviewDecision": "REVIEW_REQUIRED",
  "labels": [{"id": "LA_1", "name": "release", "description": "", "color": "e8643c"}],
  "assignees": [{"id": "1", "login": "gobinda168", "name": "Gobinda Das"}],
  "autoMergeRequest": {"mergeMethod": "SQUASH", "enabledAt": "2026-10-06T15:00:00Z", "enabledBy": {"login": "gobinda168"}},
  "closingIssuesReferences": [{"id": "I_1", "number": 12,
    "repository": {"id": "R", "name": "glance", "owner": {"id": "O", "login": "gobinda168"}},
    "url": "https://github.com/gobinda168/glance/issues/12"}],
  "files": [{"path": "scripts/release.sh", "additions": 147, "deletions": 0, "changeType": "ADDED"}],
  "url": "https://github.com/gobinda168/glance/pull/51", "isCrossRepository": false
}
"""

@Test func readsThePageGhPrints() throws {
  let page = try #require(PullRequestPage.parse(Data(viewOutput.utf8)))
  #expect(page.number == 51)
  #expect(page.title == "Release: build, sign, zip, appcast, DMG and publish")
  #expect(page.body == "## What\n- builds both apps")
  #expect(page.state == .open && !page.isDraft)
  #expect(page.author == "gobinda168")
  #expect(page.createdAt == Date(timeIntervalSince1970: 1_791_190_800))
  #expect(page.head == "feat/release" && page.base == "main")
  #expect(page.headOid == "81380ed0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6")
  #expect(page.additions == 323 && page.deletions == 15 && page.changedFiles == 19)
  #expect(page.commits.map(\.author) == ["gobinda168", "Claude"])
  #expect(page.commits.map(\.shortOid) == ["57ee700", "81380ed"])
  #expect(page.reviews.map(\.state) == [.commented, .approved, .pending])
  #expect(page.latestReviews.map(\.author) == ["claude", "mira-k"])
  #expect(page.comments == [.init(author: "devon", body: "Looks close.", createdAt: Date(timeIntervalSince1970: 1_791_288_000))])
  #expect(page.requestedReviewers == ["devon", "Release"])
  #expect(page.checks == .init(passed: 2, failed: 1, pending: 1))
  #expect(page.checkList == [.init(name: "swift test", outcome: .passed), .init(name: "lint", outcome: .skipped),
                             .init(name: "sign", outcome: .running), .init(name: "ci/legacy", outcome: .failed)])
  #expect(page.mergeable == .mergeable)
  #expect(page.mergeState == .blocked)
  #expect(page.reviewDecision == .required)
  #expect(page.labels == [.init(name: "release", color: "e8643c")])
  #expect(page.assignees == ["gobinda168"])
  #expect(page.autoMerge == .squash)
  #expect(page.closingIssues == [12])
  #expect(page.files == [.init(path: "scripts/release.sh", additions: 147, deletions: 0, change: "ADDED")])
  #expect(!page.isCrossRepository)
}

@Test func aPageWithoutItsNumberIsntAPage() {
  #expect(PullRequestPage.parse(Data(#"{"message": "Not Found"}"#.utf8)) == nil)
  #expect(PullRequestPage.parse(Data("[]".utf8)) == nil)
  #expect(PullRequestPage.parse(Data(#"{"number": 3, "title": "Bare"}"#.utf8))?.state == .open)
}

@Test func asksGhForThePagesFields() {
  let arguments = PullRequestPage.arguments(number: 51, repository: "gobinda168/glance")
  #expect(arguments.prefix(5) == ["pr", "view", "51", "--repo", "gobinda168/glance"])
  #expect(arguments.last?.contains("closingIssuesReferences") == true)
  #expect(arguments.last?.contains("mergeStateStatus") == true)
}

@Test func mergeMethodsHaveTheButtonsWordsAndGhsFlags() {
  #expect(PullRequestPage.MergeMethod.squash.title == "Squash and merge")
  #expect(PullRequestPage.MergeMethod.merge.flag == "--merge")
  #expect(PullRequestPage.MergeMethod.rebase.flag == "--rebase")
}

@Test func theActivityRunsOldestFirstWithPushesTogether() throws {
  let page = try #require(PullRequestPage.parse(Data(viewOutput.utf8)))
  let activity = PullRequestPage.activity(page)
  // The push of both commits, Claude's review, devon's comment, mira-k's approval. The pending review is the user's
  // own draft and isn't shown.
  #expect(activity.count == 4)
  guard case .pushed(let author, let commits) = activity[0] else {
    Issue.record("the activity doesn't start with the push")
    return
  }
  #expect(author == "gobinda168")
  #expect(commits.count == 2)
  #expect(activity[1] == .reviewed(page.reviews[0]))
  #expect(activity[2] == .commented(page.comments[0]))
  #expect(activity[3] == .reviewed(page.reviews[1]))
}

@Test func aCommitAfterAReviewStartsANewPush() throws {
  var page = try #require(PullRequestPage.parse(Data(viewOutput.utf8)))
  page.commits.append(.init(oid: "aaaaaaa1", headline: "fix: the review", author: "gobinda168",
                            date: Date(timeIntervalSince1970: 1_791_300_000)))
  let activity = PullRequestPage.activity(page)
  #expect(activity.count == 5)
  if case .pushed(_, let commits) = activity[4] { #expect(commits.map(\.headline) == ["fix: the review"]) }
  else { Issue.record("the last push isn't last") }
}
