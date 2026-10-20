import Foundation

/// The Review comments inbox (spec 2026-10-07-pr-manager-design.md, "Pages → Review comments"; the canvas's board 4).
/// It works out the filters and their counts, the threads by pull request, each thread's pill and words, and what Fix
/// all blocking fixes. The viewer's own pending comments stay out: nobody sees them until their review is sent.
public enum ReviewInbox {
  public enum Filter: CaseIterable, Sendable {
    case unresolved, blocking, waitingOnYou, fromPeople, fromBots, resolved

    /// The side bar's row and the page's heading.
    public var title: String {
      switch self {
      case .unresolved: "Unresolved"
      case .blocking: "Blocking"
      case .waitingOnYou: "Waiting on you"
      case .fromPeople: "From people"
      case .fromBots: "From review bots"
      case .resolved: "Resolved"
      }
    }
  }

  /// A thread card's pill.
  public enum Label: Equatable, Sendable { case blocking, optional, waitingOnYou }

  /// Won't fix's reply, before it resolves the thread.
  public static let wontFixReply = "Won't fix."

  /// Blocking wins, then Optional, then Waiting on you (on the viewer's own pull request every unanswered thread waits
  /// on them, so the severity says more). Resolved threads have none.
  public static func label(_ thread: ReviewThreads.Thread, viewer: String, author: String) -> Label? {
    guard !thread.isResolved else { return nil }
    switch ReviewThreads.severity(thread) {
    case .blocking: return .blocking
    case .optional: return .optional
    case .normal: return ReviewThreads.isWaiting(thread, on: viewer, author: author) ? .waitingOnYou : nil
    }
  }

  /// Whether `thread`, on a pull request by `author`, shows under `filter`.
  public static func matches(_ thread: ReviewThreads.Thread, _ filter: Filter, viewer: String, author: String) -> Bool {
    guard !thread.isPending else { return false }
    switch filter {
    case .unresolved: return !thread.isResolved
    case .blocking: return !thread.isResolved && ReviewThreads.severity(thread) == .blocking
    case .waitingOnYou: return ReviewThreads.isWaiting(thread, on: viewer, author: author)
    case .fromPeople: return !thread.isResolved && !ReviewThreads.isFromBot(thread)
    case .fromBots: return !thread.isResolved && ReviewThreads.isFromBot(thread)
    case .resolved: return thread.isResolved
    }
  }

  /// Every filter's count over `pullRequests`, each pull request once.
  public static func counts(_ pullRequests: [PullRequests.PullRequest], threads: [Int: [ReviewThreads.Thread]],
                            viewer: String) -> [Filter: Int] {
    var counts: [Filter: Int] = [:]
    for filter in Filter.allCases { counts[filter] = 0 }
    for pullRequest in unique(pullRequests) {
      for thread in threads[pullRequest.number] ?? [] {
        for filter in Filter.allCases where matches(thread, filter, viewer: viewer, author: pullRequest.author) {
          counts[filter, default: 0] += 1
        }
      }
    }
    return counts
  }

  /// One pull request's threads under a filter: blocking first, then waiting on you, the rest, optional last; in
  /// GitHub's order within each.
  public struct Group: Equatable, Sendable {
    public let pullRequest: PullRequests.PullRequest
    public let threads: [ReviewThreads.Thread]
  }

  /// The threads under `filter`, by pull request in the side bar's order (Waiting on you, then Yours), each pull request
  /// once. Pull requests without such a thread are left out.
  public static func groups(_ pullRequests: [PullRequests.PullRequest], threads: [Int: [ReviewThreads.Thread]],
                            filter: Filter, viewer: String) -> [Group] {
    unique(pullRequests).compactMap { pullRequest in
      let author = pullRequest.author
      let shown = (threads[pullRequest.number] ?? []).filter { matches($0, filter, viewer: viewer, author: author) }
      guard !shown.isEmpty else { return nil }
      let ordered = shown.enumerated().sorted { a, b in
        let first = rank(a.element, viewer: viewer, author: author)
        let second = rank(b.element, viewer: viewer, author: author)
        return first != second ? first < second : a.offset < b.offset
      }
      return Group(pullRequest: pullRequest, threads: ordered.map(\.element))
    }
  }

  /// The line under the heading: "6 threads across 3 pull requests · 2 block merging".
  public static func summaryLine(_ groups: [Group]) -> String {
    let threads = groups.flatMap(\.threads)
    guard !threads.isEmpty else { return "No threads" }
    var line = threads.count == 1 ? "1 thread" : "\(threads.count) threads"
    line += groups.count == 1 ? " in 1 pull request" : " across \(groups.count) pull requests"
    let blocking = threads.filter { !$0.isResolved && ReviewThreads.severity($0) == .blocking }.count
    if blocking > 0 { line += blocking == 1 ? " · 1 blocks merging" : " · \(blocking) block merging" }
    return line
  }

  /// The status bar's line: "6 unresolved · 2 blocking".
  public static func statusLine(_ counts: [Filter: Int]) -> String {
    let unresolved = counts[.unresolved] ?? 0, blocking = counts[.blocking] ?? 0
    guard unresolved > 0 else { return "No unresolved threads" }
    return blocking > 0 ? "\(unresolved) unresolved · \(blocking) blocking" : "\(unresolved) unresolved"
  }

  /// "scripts/release.sh:123"; the path alone for a comment on the file, or a line that's gone.
  public static func place(_ thread: ReviewThreads.Thread) -> String {
    if thread.isFileLevel { return thread.path }
    return (thread.line ?? thread.originalLine).map { "\(thread.path):\($0)" } ?? thread.path
  }

  /// "claude · 1 reply": who started the thread, and how many answered.
  public static func byline(_ thread: ReviewThreads.Thread) -> String {
    let author = thread.comments.first?.author ?? ""
    switch thread.comments.count {
    case 0, 1: return author
    case 2: return "\(author) · 1 reply"
    default: return "\(author) · \(thread.comments.count - 1) replies"
    }
  }

  /// What Fix all blocking does (spec): it fixes the blocking threads of the pull request checked out in the project
  /// (`branch`). Failing that, it offers to check out the one with the most (the first of a tie) and fix those.
  /// Without a blocking thread, there's nothing to do.
  public enum FixAll: Equatable, Sendable {
    case fix(PullRequests.PullRequest, [ReviewThreads.Thread])
    case checkOut(PullRequests.PullRequest, [ReviewThreads.Thread])
    case nothing
  }

  public static func fixAll(_ pullRequests: [PullRequests.PullRequest], threads: [Int: [ReviewThreads.Thread]],
                            branch: String?) -> FixAll {
    var most: (pullRequest: PullRequests.PullRequest, threads: [ReviewThreads.Thread])?
    for pullRequest in unique(pullRequests) {
      let blocking = (threads[pullRequest.number] ?? []).filter {
        !$0.isPending && !$0.isResolved && ReviewThreads.severity($0) == .blocking
      }
      guard !blocking.isEmpty else { continue }
      if let branch, pullRequest.head == branch { return .fix(pullRequest, blocking) }
      if blocking.count > (most?.threads.count ?? 0) { most = (pullRequest, blocking) }
    }
    return most.map { .checkOut($0.pullRequest, $0.threads) } ?? .nothing
  }

  /// A group's order: blocking, waiting on you, the rest, optional.
  private static func rank(_ thread: ReviewThreads.Thread, viewer: String, author: String) -> Int {
    guard let label = label(thread, viewer: viewer, author: author) else { return 2 }
    switch label {
    case .blocking: return 0
    case .waitingOnYou: return 1
    case .optional: return 3
    }
  }

  /// `thread` with `viewer`'s reply after its last comment: Reply & fix tells Claude the answer it was given.
  public static func replied(_ thread: ReviewThreads.Thread, by viewer: String, body: String) -> ReviewThreads.Thread {
    let reply = ReviewThreads.Comment(id: "", databaseID: 0, author: viewer, isBot: false, body: body, createdAt: nil,
                                      reviewState: nil)
    return ReviewThreads.Thread(
      id: thread.id, isResolved: thread.isResolved, isOutdated: thread.isOutdated, path: thread.path, line: thread.line,
      startLine: thread.startLine, side: thread.side, resolvedBy: thread.resolvedBy, comments: thread.comments + [reply],
      originalLine: thread.originalLine, startSide: thread.startSide, isFileLevel: thread.isFileLevel,
      viewerCanReply: thread.viewerCanReply, viewerCanResolve: thread.viewerCanResolve,
      viewerCanUnresolve: thread.viewerCanUnresolve)
  }

  private static func unique(_ pullRequests: [PullRequests.PullRequest]) -> [PullRequests.PullRequest] {
    var seen: Set<Int> = []
    return pullRequests.filter { seen.insert($0.number).inserted }
  }
}
