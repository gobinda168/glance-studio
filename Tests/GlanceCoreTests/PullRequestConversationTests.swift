import Foundation
import Testing
@testable import GlanceCore

private func review(_ id: String, _ author: String, at seconds: TimeInterval,
                    state: PullRequestPage.ReviewState = .commented) -> PullRequestPage.Review {
  PullRequestPage.Review(author: author, state: state, body: "", submittedAt: Date(timeIntervalSince1970: seconds),
                         id: id)
}

private func comment(_ id: String, _ author: String, at seconds: TimeInterval, review: String?,
                     pending: Bool = false) -> ReviewThreads.Comment {
  ReviewThreads.Comment(id: id, databaseID: 0, author: author, isBot: false, body: id,
                        createdAt: Date(timeIntervalSince1970: seconds), reviewState: .commented, isPending: pending,
                        reviewID: review)
}

private func thread(_ id: String, _ comments: [ReviewThreads.Comment], resolved: Bool = false) -> ReviewThreads.Thread {
  ReviewThreads.Thread(id: id, isResolved: resolved, isOutdated: false, path: "a.swift", line: 3, startLine: nil,
                       side: .right, resolvedBy: nil, comments: comments)
}

@Test func aThreadShowsWholeUnderTheReviewThatStartedIt() {
  let reviews = [review("R1", "devon", at: 100), review("R2", "gobinda", at: 200)]
  let started = thread("T1", [comment("c1", "devon", at: 90, review: "R1"), comment("c2", "devon", at: 95, review: "R1")])
  let resolved = thread("T2", [comment("c3", "devon", at: 91, review: "R1")], resolved: true)
  let parts = PullRequestPage.reviewComments(reviews, threads: [started, resolved])
  #expect(parts["R1"]?.threads.map(\.id) == ["T1", "T2"])
  #expect(parts["R1"]?.threads.first?.comments.map(\.id) == ["c1", "c2"])
  #expect(parts["R1"]?.replies.isEmpty == true)
  #expect(parts["R2"] == nil)
}

@Test func aLaterReplyShowsUnderTheReviewItCameIn() {
  let reviews = [review("R1", "devon", at: 100), review("R2", "gobinda", at: 200), review("R3", "devon", at: 300)]
  let conversation = thread("T1", [comment("c1", "devon", at: 90, review: "R1"),
                                   comment("c2", "gobinda", at: 200, review: "R2"),
                                   comment("c3", "devon", at: 300, review: "R3")])
  let parts = PullRequestPage.reviewComments(reviews, threads: [conversation])
  #expect(parts["R1"]?.threads.first?.comments.map(\.id) == ["c1", "c2", "c3"])
  #expect(parts["R2"]?.replies.map(\.comment.id) == ["c2"])
  #expect(parts["R3"]?.replies.map(\.comment.id) == ["c3"])
  #expect(parts["R3"]?.replies.first?.thread.id == "T1")
}

@Test func aCommentWithAnUnknownReviewGoesToItsAuthorsReviewOfThatTime() {
  let reviews = [review("R1", "devon", at: 100), review("R2", "devon", at: 300)]
  let early = thread("T1", [comment("c1", "devon", at: 100, review: nil)])
  let late = thread("T2", [comment("c2", "devon", at: 250, review: "R9")])
  let lost = thread("T3", [comment("c3", "devon", at: 50, review: nil)])
  let nobody = thread("T4", [comment("c4", "mira", at: 50, review: nil)])
  let parts = PullRequestPage.reviewComments(reviews, threads: [early, late, lost, nobody])
  #expect(parts["R1"]?.threads.map(\.id) == ["T1", "T2"])
  // Before any review of theirs: their last one.
  #expect(parts["R2"]?.threads.map(\.id) == ["T3"])
}

@Test func pendingCommentsStayOut() {
  let reviews = [review("R1", "devon", at: 100), review("R2", "gobinda", at: 0, state: .pending)]
  let replied = thread("T1", [comment("c1", "devon", at: 90, review: "R1"),
                              comment("c2", "gobinda", at: 120, review: "R2", pending: true)])
  let draft = thread("T2", [comment("c3", "gobinda", at: 130, review: "R2", pending: true)])
  let parts = PullRequestPage.reviewComments(reviews, threads: [replied, draft])
  #expect(parts["R1"]?.threads.first?.comments.map(\.id) == ["c1"])
  #expect(parts["R2"] == nil)
}

@Test func reviewsAndThreadCommentsCarryTheirReviewIDs() throws {
  let page = try #require(PullRequestPage.parse(Data(viewOutput.utf8)))
  #expect(page.reviews.map(\.id) == ["PRR_1", "PRR_2", "PRR_3"])
  let data = Data("""
  {"data":{"viewer":{"login":"me"},"repository":{"pullRequest":{"id":"PR_1","baseRef":null,
  "reviewThreads":{"nodes":[{"id":"T","isResolved":false,"isOutdated":false,"path":"a","line":1,"diffSide":"RIGHT",
  "comments":{"nodes":[{"id":"C","databaseId":1,"body":"x","createdAt":"2026-10-06T10:00:00Z",
  "author":{"login":"devon","__typename":"User"},"pullRequestReview":{"id":"PRR_1","state":"COMMENTED"}}]}}]}}}}}
  """.utf8)
  let extras = try #require(ReviewThreads.parsePage(data))
  #expect(extras.threads.first?.comments.first?.reviewID == "PRR_1")
}
