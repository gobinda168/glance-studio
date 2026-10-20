import Foundation
import Testing
@testable import GlanceCore

/// The page query's answer, shaped as GitHub sends it (threads from cli/cli PR 14519's form).
private let pageOutput = """
{"data":{"viewer":{"login":"gobinda168"},"repository":{"pullRequest":{"id":"PR_kwDO51",
"baseRef":{"branchProtectionRule":{"requiredApprovingReviewCount":2}},
"reviewThreads":{"nodes":[
 {"id":"PRRT_1","isResolved":false,"isOutdated":false,"path":"scripts/release.sh","line":123,"startLine":null,
  "diffSide":"RIGHT","resolvedBy":null,"comments":{"nodes":[
   {"id":"PRRC_1","databaseId":4106126529,"body":"🛑 Requirement: roll the release back when the upload fails.",
    "createdAt":"2026-10-06T10:00:00Z","author":{"login":"claude","__typename":"Bot"},
    "pullRequestReview":{"state":"COMMENTED"}},
   {"id":"PRRC_2","databaseId":4106126530,"body":"Rolling back is simpler. Applying it.",
    "createdAt":"2026-10-07T09:00:00Z","author":{"login":"gobinda168","__typename":"User"},
    "pullRequestReview":{"state":"COMMENTED"}}]}},
 {"id":"PRRT_2","isResolved":false,"isOutdated":false,"path":"docs/testing.md","line":14,"startLine":12,
  "diffSide":"RIGHT","resolvedBy":null,"comments":{"nodes":[
   {"id":"PRRC_3","databaseId":4106126531,"body":"Nit: say macOS asks once.","createdAt":"2026-10-06T10:01:00Z",
    "author":{"login":"claude","__typename":"Bot"},"pullRequestReview":{"state":"COMMENTED"}}]}},
 {"id":"PRRT_3","isResolved":true,"isOutdated":true,"path":"scripts/build.sh","line":null,"startLine":null,
  "diffSide":"LEFT","resolvedBy":{"login":"gobinda168"},"comments":{"nodes":[
   {"id":"PRRC_4","databaseId":4106126532,"body":"**Blocking:** quote the path.","createdAt":"2026-10-05T10:00:00Z",
    "author":{"login":"devon","__typename":"User"},"pullRequestReview":{"state":"CHANGES_REQUESTED"}}]}}
]}}}}}
"""

private func thread(_ body: String, state: PullRequestPage.ReviewState? = .commented, author: String = "devon",
                    resolved: Bool = false, replies: [String] = []) -> ReviewThreads.Thread {
  let first = ReviewThreads.Comment(id: "c0", databaseID: 1, author: author, isBot: false, body: body, createdAt: nil,
                                    reviewState: state)
  let rest = replies.enumerated().map { index, login in
    ReviewThreads.Comment(id: "c\(index + 1)", databaseID: index + 2, author: login, isBot: false, body: "ok",
                          createdAt: nil, reviewState: .commented)
  }
  return .init(id: "t", isResolved: resolved, isOutdated: false, path: "a.swift", line: 1, startLine: nil,
               side: .right, resolvedBy: nil, comments: [first] + rest)
}

@Test func readsThePagesThreadsViewerAndRequiredApprovals() throws {
  let extras = try #require(ReviewThreads.parsePage(Data(pageOutput.utf8)))
  #expect(extras.viewer == "gobinda168")
  #expect(extras.pullRequestID == "PR_kwDO51")
  #expect(extras.requiredApprovals == 2)
  #expect(extras.threads.map(\.path) == ["scripts/release.sh", "docs/testing.md", "scripts/build.sh"])
  let first = extras.threads[0]
  #expect(first.line == 123 && first.startLine == nil && first.side == .right && !first.isResolved)
  #expect(first.comments.map(\.author) == ["claude", "gobinda168"])
  #expect(first.comments[0].isBot && !first.comments[1].isBot)
  #expect(first.comments[0].databaseID == 4106126529)
  #expect(extras.threads[1].startLine == 12)
  #expect(extras.threads[2].resolvedBy == "gobinda168" && extras.threads[2].side == .left)
  #expect(extras.blocking.map(\.id) == ["PRRT_1"]) // the resolved blocking one doesn't count
  #expect(extras.unresolvedCount == 2)
}

@Test func blockingAndOptionalComeFromTheFirstLine() {
  #expect(ReviewThreads.severity(thread("🛑 Requirement: scope this.")) == .blocking)
  #expect(ReviewThreads.severity(thread("🔴 Important: the feed upload")) == .blocking)
  #expect(ReviewThreads.severity(thread("**Blocking:** quote the path")) == .blocking)
  #expect(ReviewThreads.severity(thread("This must fix the order.")) == .blocking)
  #expect(ReviewThreads.severity(thread("Nit: a typo")) == .optional)
  #expect(ReviewThreads.severity(thread("nitpick, take it or leave it")) == .optional)
  #expect(ReviewThreads.severity(thread("Non-blocking: rename this")) == .optional)
  #expect(ReviewThreads.severity(thread("🟡 Minor: spacing")) == .optional)
  #expect(ReviewThreads.severity(thread("(optional) a helper")) == .optional)
  #expect(ReviewThreads.severity(thread("Looks good.\nBut blocking is said on line two.")) == .normal)
  #expect(ReviewThreads.severity(thread("Please rename.", state: .changesRequested)) == .blocking)
  #expect(ReviewThreads.severity(thread("Nit: rename.", state: .changesRequested)) == .optional)
  #expect(ReviewThreads.severity(thread("Unit tests would help.")) == .normal) // "unit" isn't "nit"
}

@Test func botsAreBotTypedOrBotNamed() {
  var bot = thread("x")
  #expect(!ReviewThreads.isFromBot(bot))
  bot = thread("x", author: "copilot-pull-request-reviewer[bot]")
  #expect(ReviewThreads.isFromBot(bot))
  let typed = ReviewThreads.Thread(id: "t", isResolved: false, isOutdated: false, path: "a", line: 1, startLine: nil,
                                   side: .right, resolvedBy: nil, comments: [
                                     .init(id: "c", databaseID: 1, author: "claude", isBot: true, body: "x",
                                           createdAt: nil, reviewState: nil)])
  #expect(ReviewThreads.isFromBot(typed))
}

@Test func aThreadWaitsOnYouWhenSomeoneElseHadTheLastWord() {
  // On your pull request: devon spoke last.
  #expect(ReviewThreads.isWaiting(thread("Why?"), on: "gobinda168", author: "gobinda168"))
  // You answered last.
  #expect(!ReviewThreads.isWaiting(thread("Why?", replies: ["gobinda168"]), on: "gobinda168", author: "gobinda168"))
  // Someone else's pull request where you spoke, then its author replied.
  #expect(ReviewThreads.isWaiting(thread("Rename?", author: "gobinda168", replies: ["mira-k"]), on: "gobinda168",
                                  author: "mira-k"))
  // Someone else's pull request you never spoke in.
  #expect(!ReviewThreads.isWaiting(thread("Rename?"), on: "gobinda168", author: "mira-k"))
  // Resolved threads wait on nobody.
  #expect(!ReviewThreads.isWaiting(thread("Why?", resolved: true), on: "gobinda168", author: "gobinda168"))
}

@Test func theBoardAsksForEveryPullRequestsThreadsAtOnce() throws {
  let query = ReviewThreads.boardQuery(numbers: [51, 49])
  #expect(query.contains("viewer { login }"))
  #expect(query.contains("pr51: pullRequest(number: 51)"))
  #expect(query.contains("pr49: pullRequest(number: 49)"))
  #expect(query.contains("comments(first: 50)")) // whole threads: the inbox shows them
  #expect(ReviewThreads.boardArguments(repository: "gobinda168/glance", numbers: []) == nil)
  let arguments = try #require(ReviewThreads.boardArguments(repository: "gobinda168/glance", numbers: [51]))
  #expect(arguments.contains("owner=gobinda168") && arguments.contains("name=glance"))
  let output = """
    {"data":{"viewer":{"login":"gobinda168"},"repository":{
    "pr51":{"reviewThreads":{"nodes":[
      {"id":"T1","isResolved":false,"path":"a.swift","line":3,"comments":{"nodes":[{"id":"C1","body":"🔴 Important",
        "author":{"login":"claude","__typename":"Bot"},"pullRequestReview":{"state":"COMMENTED"}}]}},
      {"id":"T2","isResolved":false,"path":"a.swift","line":9,"comments":{"nodes":[{"id":"C2","body":"Nit: x",
        "author":{"login":"claude","__typename":"Bot"},"pullRequestReview":{"state":"COMMENTED"}}]}},
      {"id":"T3","isResolved":true,"path":"b.swift","line":1,"comments":{"nodes":[{"id":"C3","body":"Blocking: y",
        "author":{"login":"devon","__typename":"User"},"pullRequestReview":{"state":"COMMENTED"}}]}},
      {"id":"T4","isResolved":false,"path":"b.swift","line":2,"comments":{"nodes":[{"id":"C4","body":"Blocking: mine",
        "state":"PENDING","author":{"login":"gobinda168","__typename":"User"},
        "pullRequestReview":{"state":"PENDING"}}]}}]}},
    "pr49":{"reviewThreads":{"nodes":[]}}}}}
    """
  let board = try #require(ReviewThreads.parseBoard(Data(output.utf8)))
  #expect(board.viewer == "gobinda168")
  #expect(board.threads[51]?.map(\.id) == ["T1", "T2", "T3", "T4"])
  #expect(board.threads[49] == [])
  // The resolved thread counts for nothing; the viewer's own pending comment isn't a thread anyone answers yet.
  #expect(ReviewThreads.summary(board.threads[51] ?? []) == .init(unresolved: 2, blocking: 1))
  #expect(ReviewThreads.summary([]) == .init(unresolved: 0, blocking: 0))
}
