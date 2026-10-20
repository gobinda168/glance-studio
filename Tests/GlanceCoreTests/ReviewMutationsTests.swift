import Foundation
import Testing
@testable import GlanceCore

/// The flag in front of `value` ("-f" for text, "-F" for numbers); nil when it isn't there.
private func flag(_ arguments: [String], _ value: String) -> String? {
  guard let index = arguments.firstIndex(of: value), index > 0 else { return nil }
  return arguments[index - 1]
}

private func query(_ arguments: [String]) -> String {
  arguments.first { $0.hasPrefix("query=") } ?? ""
}

@Test func aCommentStartsThePendingReviewFirst() {
  let start = ReviewMutations.startReview(pullRequestID: "PR_1")
  #expect(query(start).contains("addPullRequestReview(input: {pullRequestId: $pullRequestId})"))
  #expect(!query(start).contains("event")) // no verdict: it stays pending
  #expect(flag(start, "pullRequestId=PR_1") == "-f")
  let answer = #"{"data":{"addPullRequestReview":{"pullRequestReview":{"id":"PRR_7"}}}}"#
  #expect(ReviewMutations.reviewID(from: Data(answer.utf8)) == "PRR_7")
  #expect(ReviewMutations.reviewID(from: Data(#"{"errors":[{"message":"no"}]}"#.utf8)) == nil)
}

@Test func aThreadGoesOnALineOrARange() {
  let range = ReviewMutations.addThread(reviewID: "PRR_7", path: "scripts/release.sh", body: "Fall back?", line: 119,
                                        side: .right, startLine: 117, startSide: .right)
  #expect(query(range).contains("addPullRequestReviewThread"))
  #expect(flag(range, "reviewId=PRR_7") == "-f")
  #expect(flag(range, "path=scripts/release.sh") == "-f")
  #expect(flag(range, "body=Fall back?") == "-f")
  #expect(flag(range, "line=119") == "-F")
  #expect(flag(range, "side=RIGHT") == "-f")
  #expect(flag(range, "startLine=117") == "-F")
  #expect(flag(range, "startSide=RIGHT") == "-f")
  let one = ReviewMutations.addThread(reviewID: "PRR_7", path: "a", body: "b", line: 3, side: .left, startLine: nil,
                                      startSide: nil)
  #expect(flag(one, "side=LEFT") == "-f")
  #expect(!one.contains { $0.hasPrefix("startLine=") || $0.hasPrefix("startSide=") })
}

@Test func repliesEditsDeletesAndResolving() {
  let reply = ReviewMutations.reply(threadID: "PRRT_1", body: "Applying it.")
  #expect(query(reply).contains("addPullRequestReviewThreadReply"))
  #expect(flag(reply, "threadId=PRRT_1") == "-f" && flag(reply, "body=Applying it.") == "-f")
  let edit = ReviewMutations.editComment(id: "PRRC_1", body: "Better words")
  #expect(query(edit).contains("updatePullRequestReviewComment") && flag(edit, "id=PRRC_1") == "-f")
  #expect(flag(edit, "body=Better words") == "-f")
  #expect(query(ReviewMutations.deleteComment(id: "PRRC_1")).contains("deletePullRequestReviewComment"))
  #expect(query(ReviewMutations.resolve(threadID: "PRRT_1")).contains("resolveReviewThread"))
  #expect(query(ReviewMutations.unresolve(threadID: "PRRT_1")).contains("unresolveReviewThread"))
}

@Test func viewedFilesAreMarkedAndUnmarked() {
  let mark = ReviewMutations.setViewed(pullRequestID: "PR_1", path: "README.md", viewed: true)
  #expect(query(mark).contains("markFileAsViewed") && !query(mark).contains("unmarkFileAsViewed"))
  #expect(flag(mark, "path=README.md") == "-f" && flag(mark, "pullRequestId=PR_1") == "-f")
  let unmark = ReviewMutations.setViewed(pullRequestID: "PR_1", path: "README.md", viewed: false)
  #expect(query(unmark).contains("unmarkFileAsViewed"))
}

@Test func finishReviewSubmitsThePendingReviewOrPostsOne() {
  let submit = ReviewMutations.submit(reviewID: "PRR_7", event: .requestChanges, body: "Two blocking threads.")
  #expect(query(submit).contains("submitPullRequestReview"))
  #expect(flag(submit, "event=REQUEST_CHANGES") == "-f" && flag(submit, "body=Two blocking threads.") == "-f")
  #expect(flag(submit, "reviewId=PRR_7") == "-f")
  let review = ReviewMutations.review(pullRequestID: "PR_1", event: .approve, body: "")
  #expect(query(review).contains("addPullRequestReview") && flag(review, "event=APPROVE") == "-f")
  #expect(flag(review, "pullRequestId=PR_1") == "-f")
}
