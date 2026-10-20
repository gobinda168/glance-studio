import Foundation

extension PullRequestPage {
  /// The Merge readiness card (board 1): one row each for checks, conflicts, blocking threads and approvals, the pill,
  /// and what the merge button may do.
  public struct Readiness: Equatable, Sendable {
    public enum Tone: Equatable, Sendable { case ok, pending, blocked }

    public enum Pill: Equatable, Sendable {
      case ready, pending, draft, merged, closed
      /// How many things block it: failing checks, blocking threads, a conflict, a request for changes.
      case blocked(Int)
    }

    public struct Row: Equatable, Sendable {
      public enum Kind: Equatable, Sendable { case checks, conflicts, threads, approvals }

      public let kind: Kind
      public let tone: Tone
      public let title: String
      public let detail: String
    }

    public let rows: [Row]
    public let pill: Pill
    /// GitHub would merge it now.
    public let canMerge: Bool
    /// Only Glance's own blockers are left (blocking threads): merging asks first.
    public let asksFirst: Bool
    /// GitHub says the branch is behind its base.
    public let canUpdateBranch: Bool
  }

  public struct Reviewer: Equatable, Sendable {
    public enum State: Equatable, Sendable { case approved, changesRequested, commented, pending }

    public let login: String
    public let state: State
  }

  public static func readiness(_ page: Page, blockingThreads: Int, requiredApprovals: Int?) -> Readiness {
    var rows: [Readiness.Row] = []
    let checks = page.checks
    switch checks.state {
    case .empty:
      rows.append(.init(kind: .checks, tone: .ok, title: "Checks", detail: "None on this branch"))
    case .failing:
      rows.append(.init(kind: .checks, tone: .blocked, title: "Checks", detail: "\(checks.failed) of \(checks.total) failing"))
    case .pending:
      rows.append(.init(kind: .checks, tone: .pending, title: "Checks", detail: "\(checks.pending) of \(checks.total) running"))
    case .passing:
      rows.append(.init(kind: .checks, tone: .ok, title: "Checks", detail: "\(checks.passed) of \(checks.total) passing"))
    }

    let conflicting = page.mergeable == .conflicting || page.mergeState == .dirty
    if conflicting {
      rows.append(.init(kind: .conflicts, tone: .blocked, title: "Conflicts",
                        detail: "With \(page.base): resolve them to merge"))
    } else if page.mergeState == .behind {
      rows.append(.init(kind: .conflicts, tone: .pending, title: "Behind \(page.base)", detail: "Update the branch to merge"))
    } else if page.mergeable == .unknown || page.mergeState == .unknown {
      rows.append(.init(kind: .conflicts, tone: .pending, title: "Conflicts", detail: "GitHub is still checking"))
    } else {
      rows.append(.init(kind: .conflicts, tone: .ok, title: "No conflicts", detail: "Up to date with \(page.base)"))
    }

    if blockingThreads > 0 {
      rows.append(.init(kind: .threads, tone: .blocked,
                        title: blockingThreads == 1 ? "1 blocking thread" : "\(blockingThreads) blocking threads",
                        detail: "Unresolved review comments"))
    }

    let approved = page.latestReviews.filter { $0.state == .approved }.count
    let requesters = page.latestReviews.filter { $0.state == .changesRequested }.map(\.author)
    if !requesters.isEmpty {
      rows.append(.init(kind: .approvals, tone: .blocked, title: "Changes requested",
                        detail: "By " + requesters.joined(separator: ", ")))
    } else if let required = requiredApprovals, required > 0 {
      rows.append(.init(kind: .approvals, tone: approved >= required ? .ok : .pending, title: "Approvals",
                        detail: "\(approved) of \(required) required"))
    } else if page.reviewDecision == .required {
      rows.append(.init(kind: .approvals, tone: .pending, title: "Approvals", detail: "Review required"))
    } else {
      rows.append(.init(kind: .approvals, tone: .ok, title: "Approvals",
                        detail: approved == 0 ? "None required" : approved == 1 ? "1 approval" : "\(approved) approvals"))
    }

    let blockers = checks.failed + (conflicting ? 1 : 0) + blockingThreads + (requesters.isEmpty ? 0 : 1)
    let pill: Readiness.Pill
    switch page.state {
    case .merged: pill = .merged
    case .closed: pill = .closed
    case .open:
      if page.isDraft {
        pill = .draft
      } else if blockers > 0 {
        pill = .blocked(blockers)
      } else if rows.contains(where: { $0.tone == .pending }) {
        pill = .pending
      } else {
        pill = .ready
      }
    }
    let canMerge = page.state == .open && !page.isDraft && [.clean, .hasHooks, .unstable].contains(page.mergeState)
    return Readiness(rows: rows, pill: pill, canMerge: canMerge, asksFirst: canMerge && blockingThreads > 0,
                     canUpdateBranch: page.state == .open && page.mergeState == .behind)
  }

  /// Who reviewed (each one's latest review) and who's still asked, in that order. Someone asked again is pending
  /// again; the author's own comments don't make them a reviewer.
  public static func reviewers(_ page: Page) -> [Reviewer] {
    let asked = Set(page.requestedReviewers)
    var seen: Set<String> = []
    var reviewers: [Reviewer] = []
    for review in page.latestReviews where review.author != page.author && !asked.contains(review.author) {
      let state: Reviewer.State
      switch review.state {
      case .approved: state = .approved
      case .changesRequested: state = .changesRequested
      case .commented: state = .commented
      case .dismissed, .pending: continue
      }
      guard seen.insert(review.author).inserted else { continue }
      reviewers.append(Reviewer(login: review.author, state: state))
    }
    for login in page.requestedReviewers where seen.insert(login).inserted {
      reviewers.append(Reviewer(login: login, state: .pending))
    }
    return reviewers
  }
}
