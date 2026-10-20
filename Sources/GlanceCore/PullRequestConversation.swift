import Foundation

/// The review comments the Overview shows with each review (spec 2026-10-12-pr-sidebar-tabs-design.md, "The PR tab"):
/// every thread under the review that started it, whole with its replies, and a reply posted later under the review
/// it came in, so someone's comment on your pull request is on the page whichever review it rode in.
extension PullRequestPage {
  /// A reply posted in one review to a thread another review started.
  public struct Reply: Equatable, Sendable {
    public let thread: ReviewThreads.Thread
    public let comment: ReviewThreads.Comment
  }

  /// What a review shows under its words.
  public struct ReviewComments: Equatable, Sendable {
    /// The threads it started, with every reply, resolved ones too.
    public var threads: [ReviewThreads.Thread] = []
    /// Its replies to threads another review started.
    public var replies: [Reply] = []

    public init(threads: [ReviewThreads.Thread] = [], replies: [Reply] = []) {
      self.threads = threads
      self.replies = replies
    }

    public var isEmpty: Bool { threads.isEmpty && replies.isEmpty }
  }

  /// Each shown review's comments, by review id. A comment goes to the review it was posted in; one whose review
  /// isn't among `reviews` (an older gh, a review past the first page) goes to its author's last review submitted by
  /// then, else their last one. The viewer's pending comments stay out: only they see them, on the Files page.
  public static func reviewComments(_ reviews: [Review], threads: [ReviewThreads.Thread]) -> [String: ReviewComments] {
    let shown = reviews.filter { $0.state != .pending && !$0.id.isEmpty }
    let ids = Set(shown.map(\.id))
    func home(_ comment: ReviewThreads.Comment) -> String? {
      if let id = comment.reviewID, ids.contains(id) { return id }
      let theirs = shown.filter { $0.author == comment.author }
      let date = comment.createdAt ?? .distantFuture
      return (theirs.last { ($0.submittedAt ?? .distantPast) <= date } ?? theirs.last)?.id
    }
    var result: [String: ReviewComments] = [:]
    for thread in threads {
      let posted = thread.comments.filter { !$0.isPending }
      guard let first = posted.first else { continue }
      let shownThread = thread.with(comments: posted)
      let started = home(first)
      if let started { result[started, default: ReviewComments()].threads.append(shownThread) }
      for comment in posted.dropFirst() {
        guard let review = home(comment), review != started else { continue }
        result[review, default: ReviewComments()].replies.append(Reply(thread: shownThread, comment: comment))
      }
    }
    return result
  }
}

extension ReviewThreads.Thread {
  /// The same thread with `comments` instead of its own.
  func with(comments: [ReviewThreads.Comment]) -> ReviewThreads.Thread {
    ReviewThreads.Thread(id: id, isResolved: isResolved, isOutdated: isOutdated, path: path, line: line,
                         startLine: startLine, side: side, resolvedBy: resolvedBy, comments: comments,
                         originalLine: originalLine, startSide: startSide, isFileLevel: isFileLevel,
                         viewerCanReply: viewerCanReply, viewerCanResolve: viewerCanResolve,
                         viewerCanUnresolve: viewerCanUnresolve)
  }
}
