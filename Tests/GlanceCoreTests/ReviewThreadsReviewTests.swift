import Foundation
import Testing
@testable import GlanceCore

/// The PR page's query answered for a pull request under review, shaped as GitHub sends it:
/// - the viewer's pending review holding two comments;
/// - a first page of files with more after it (one viewed, one changed since it was viewed);
/// - a pending range comment;
/// - a comment on a whole file.
private let reviewPage = """
{"data":{"viewer":{"login":"gobinda168"},"repository":{"pullRequest":{"id":"PR_kwDO51","baseRef":null,
"reviews":{"nodes":[{"id":"PRR_pending","comments":{"totalCount":2}}]},
"files":{"pageInfo":{"hasNextPage":true,"endCursor":"Y3Vyc29yOjEwMA=="},"nodes":[
 {"path":"scripts/release.sh","viewerViewedState":"UNVIEWED"},
 {"path":"scripts/sign-app.sh","viewerViewedState":"VIEWED"},
 {"path":"README.md","viewerViewedState":"DISMISSED"}]},
"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":"eA=="},"nodes":[
 {"id":"PRRT_9","isResolved":false,"isOutdated":false,"path":"scripts/release.sh","line":119,"startLine":117,
  "originalLine":119,"diffSide":"RIGHT","startDiffSide":"RIGHT","subjectType":"LINE","resolvedBy":null,
  "viewerCanReply":true,"viewerCanResolve":true,"viewerCanUnresolve":false,
  "comments":{"nodes":[{"id":"PRRC_9","databaseId":9,"body":"Should --notes fall back?",
   "createdAt":"2026-10-07T09:00:00Z","state":"PENDING","viewerDidAuthor":true,"viewerCanUpdate":true,
   "viewerCanDelete":true,"author":{"login":"gobinda168","__typename":"User"},"pullRequestReview":{"state":"PENDING"}}]}},
 {"id":"PRRT_10","isResolved":false,"isOutdated":false,"path":"docs/testing.md","line":null,"startLine":null,
  "originalLine":null,"diffSide":"RIGHT","startDiffSide":null,"subjectType":"FILE","resolvedBy":null,
  "viewerCanReply":true,"viewerCanResolve":true,"viewerCanUnresolve":false,
  "comments":{"nodes":[{"id":"PRRC_10","databaseId":10,"body":"Split this file.","createdAt":"2026-10-06T09:00:00Z",
   "state":"SUBMITTED","viewerDidAuthor":false,"viewerCanUpdate":false,"viewerCanDelete":false,
   "author":{"login":"devon","__typename":"User"},"pullRequestReview":{"state":"COMMENTED"}}]}}
]}}}}}
"""

private func reviewThread(_ id: String, _ side: ReviewThreads.Thread.Side, _ line: Int?, path: String = "a.swift",
                          outdated: Bool = false, fileLevel: Bool = false,
                          resolved: Bool = false) -> ReviewThreads.Thread {
  .init(id: id, isResolved: resolved, isOutdated: outdated, path: path, line: line, startLine: nil, side: side,
        resolvedBy: nil, comments: [], isFileLevel: fileLevel)
}

@Test func theReviewPageReadsViewedFilesThePendingReviewAndMorePages() throws {
  let extras = try #require(ReviewThreads.parsePage(Data(reviewPage.utf8)))
  #expect(extras.viewed == ["scripts/sign-app.sh"]) // DISMISSED (changed since) isn't viewed
  #expect(extras.pendingReviewID == "PRR_pending" && extras.pendingCount == 2)
  #expect(extras.moreFiles == "Y3Vyc29yOjEwMA==" && extras.moreThreads == nil)
  #expect(extras.requiredApprovals == nil)
  let pending = extras.threads[0]
  #expect(pending.isPending && pending.startLine == 117 && pending.startSide == .right && pending.originalLine == 119)
  #expect(pending.viewerCanReply && pending.viewerCanResolve && !pending.viewerCanUnresolve)
  #expect(pending.comments[0].isPending && pending.comments[0].viewerDidAuthor && pending.comments[0].viewerCanUpdate
    && pending.comments[0].viewerCanDelete)
  #expect(extras.threads[1].isFileLevel && !extras.threads[1].isPending)
}

@Test func furtherPagesOfFilesAndThreadsAreAskedForAndRead() throws {
  let arguments = try #require(ReviewThreads.moreArguments(ReviewThreads.moreFilesQuery, repository: "o/r", number: 51,
                                                           after: "abc"))
  #expect(arguments.contains("after=abc") && arguments.contains("number=51") && arguments.contains("owner=o"))
  #expect(ReviewThreads.moreArguments(ReviewThreads.moreThreadsQuery, repository: "nonsense", number: 1, after: "x")
    == nil)
  let files = #"{"data":{"repository":{"pullRequest":{"files":{"pageInfo":{"hasNextPage":false,"endCursor":"z"},"#
    + #""nodes":[{"path":"a.swift","viewerViewedState":"VIEWED"},{"path":"b.swift","viewerViewedState":"UNVIEWED"}]}}}}}"#
  #expect(ReviewThreads.parseMoreFiles(Data(files.utf8)) == .init(viewed: ["a.swift"], next: nil))
  let threads = #"{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"#
    + #""endCursor":"c2"},"nodes":[{"id":"PRRT_200","isResolved":true,"path":"a.swift","line":3,"diffSide":"LEFT","#
    + #""comments":{"nodes":[]}}]}}}}}"#
  let more = try #require(ReviewThreads.parseMoreThreads(Data(threads.utf8)))
  #expect(more.threads.map(\.id) == ["PRRT_200"] && more.threads[0].side == .left && more.next == "c2")
}

@Test func threadsSitUnderTheirLineOnTheFileOrFoldedAsOutdated() {
  let text = ["diff --git a/a.swift b/a.swift", "--- a/a.swift", "+++ b/a.swift", "@@ -1,3 +1,3 @@", " one", "-two",
              "+TWO", " three"].joined(separator: "\n")
  let file = PullRequestDiff.parse(text)[0]
  let threads = [
    reviewThread("t1", .right, 2), reviewThread("t2", .left, 2), reviewThread("t3", .right, 3),
    reviewThread("t4", .left, 3), reviewThread("t5", .right, 9), reviewThread("t6", .right, 1, outdated: true),
    reviewThread("t7", .right, nil, fileLevel: true), reviewThread("t8", .right, 2, path: "b.swift"),
  ]
  let placement = ReviewThreads.placement(threads, path: "a.swift", file: file)
  #expect(placement.anchored[.init(side: .right, line: 2)]?.map(\.id) == ["t1"])
  #expect(placement.anchored[.init(side: .left, line: 2)]?.map(\.id) == ["t2"])
  // A context line carries both sides' threads.
  #expect(placement.anchored[.init(side: .right, line: 3)]?.map(\.id) == ["t3"])
  #expect(placement.anchored[.init(side: .left, line: 3)]?.map(\.id) == ["t4"])
  // Line 9 isn't in the diff, and t6 GitHub calls outdated: neither vanishes.
  #expect(placement.outdated.map(\.id) == ["t5", "t6"])
  #expect(placement.fileLevel.map(\.id) == ["t7"])
  #expect(placement.anchored.values.flatMap { $0 }.count == 4) // t8 is another file's
}

@Test func eachFileCountsItsOpenThreads() {
  let threads = [reviewThread("a", .right, 1), reviewThread("b", .right, 2),
                 reviewThread("c", .right, 3, resolved: true), reviewThread("d", .right, 1, path: "b.swift")]
  #expect(ReviewThreads.openCounts(threads) == ["a.swift": 2, "b.swift": 1])
}

@Test func aSuggestionIsReadFromItsFenceEvenWithCRLF() {
  let body = "Roll the release back when the upload fails:\r\n```suggestion\r\n  gh release upload \"$1\" \\\r\n"
    + "    || rollback\r\n```\r\nThen tell the tester."
  #expect(ReviewThreads.suggestion(in: body) == .init(
    before: "Roll the release back when the upload fails:",
    lines: ["  gh release upload \"$1\" \\", "    || rollback"],
    after: "Then tell the tester."))
  #expect(ReviewThreads.suggestion(in: "No fence here.") == nil)
  #expect(ReviewThreads.suggestion(in: "Drop these:\n```suggestion\n```")?.lines == [])
  #expect(ReviewThreads.suggestion(in: "```swift\nlet a = 1\n```") == nil)
  #expect(ReviewThreads.suggestion(in: "```suggestion\nno closing fence") == nil)
}
