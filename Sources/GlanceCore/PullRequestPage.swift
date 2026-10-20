import Foundation

/// One pull request as its PR tab shows it (spec 2026-10-07-pr-manager-design.md, "Pages"): `gh pr view --json`
/// parsed, and its activity in order. Merge readiness and reviewers are in PullRequestReadiness.swift.
public enum PullRequestPage {
  public enum State: String, Sendable { case open = "OPEN", closed = "CLOSED", merged = "MERGED" }

  /// GitHub's `mergeStateStatus`: whether GitHub would merge it now, and if not, why.
  public enum MergeState: String, Sendable {
    case behind = "BEHIND", blocked = "BLOCKED", clean = "CLEAN", dirty = "DIRTY", draft = "DRAFT"
    case hasHooks = "HAS_HOOKS", unknown = "UNKNOWN", unstable = "UNSTABLE"
  }

  public enum ReviewState: String, Sendable {
    case approved = "APPROVED", changesRequested = "CHANGES_REQUESTED", commented = "COMMENTED"
    case dismissed = "DISMISSED", pending = "PENDING"
  }

  public enum MergeMethod: String, CaseIterable, Sendable {
    case merge = "MERGE", squash = "SQUASH", rebase = "REBASE"

    /// The merge button's words.
    public var title: String {
      switch self {
      case .merge: "Create a merge commit"
      case .squash: "Squash and merge"
      case .rebase: "Rebase and merge"
      }
    }

    /// `gh pr merge`'s flag.
    public var flag: String {
      switch self {
      case .merge: "--merge"
      case .squash: "--squash"
      case .rebase: "--rebase"
      }
    }
  }

  public struct Commit: Equatable, Sendable {
    public let oid: String
    public let headline: String
    /// The first author's login, else their name.
    public let author: String
    public let date: Date?

    public var shortOid: String { String(oid.prefix(7)) }
  }

  public struct Review: Equatable, Sendable {
    public let author: String
    public let state: ReviewState
    public let body: String
    public let submittedAt: Date?
    /// Its GraphQL id ("PRR_…"), which its threads' comments name.
    public let id: String
  }

  public struct Comment: Equatable, Sendable {
    public let author: String
    public let body: String
    public let createdAt: Date?
  }

  public struct Label: Equatable, Sendable {
    public let name: String
    /// Hex, without "#".
    public let color: String

    public init(name: String, color: String) {
      self.name = name
      self.color = color
    }
  }

  public struct File: Equatable, Sendable {
    public let path: String
    public let additions: Int
    public let deletions: Int
    /// ADDED, MODIFIED, DELETED, RENAMED, COPIED or CHANGED.
    public let change: String

    public init(path: String, additions: Int, deletions: Int, change: String) {
      self.path = path
      self.additions = additions
      self.deletions = deletions
      self.change = change
    }
  }

  /// One check of the head commit, from the rollup.
  public struct Check: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable { case passed, failed, running, skipped }

    public let name: String
    public let outcome: Outcome
  }

  public struct Page: Equatable, Sendable {
    public var number: Int
    public var title: String
    public var body: String
    public var state: State
    public var isDraft: Bool
    public var author: String
    public var createdAt: Date?
    public var head: String
    public var headOid: String
    public var base: String
    public var additions: Int
    public var deletions: Int
    public var changedFiles: Int
    public var commits: [Commit]
    public var reviews: [Review]
    /// Each reviewer's latest review.
    public var latestReviews: [Review]
    public var comments: [Comment]
    /// People (logins) and teams (names) asked to review who haven't yet.
    public var requestedReviewers: [String]
    public var checks: PullRequests.Checks
    public var checkList: [Check]
    public var mergeable: PullRequests.PullRequest.Mergeable
    public var mergeState: MergeState
    public var reviewDecision: PullRequests.PullRequest.Review
    public var labels: [Label]
    public var assignees: [String]
    /// The method auto-merge will use, while it's on.
    public var autoMerge: MergeMethod?
    /// The issues it closes when merged.
    public var closingIssues: [Int]
    public var files: [File]
    public var isCrossRepository: Bool
  }

  /// Commits in a row become one push; reviews and comments are their own entries.
  public enum Activity: Equatable, Sendable {
    case pushed(author: String, commits: [Commit])
    case reviewed(Review)
    case commented(Comment)
  }

  public static let fields = "number,title,body,state,isDraft,author,createdAt,headRefName,headRefOid,baseRefName,"
    + "additions,deletions,changedFiles,commits,reviews,latestReviews,comments,reviewRequests,statusCheckRollup,"
    + "mergeable,mergeStateStatus,reviewDecision,labels,assignees,autoMergeRequest,closingIssuesReferences,files,"
    + "isCrossRepository"

  public static func arguments(number: Int, repository: String) -> [String] {
    ["pr", "view", String(number), "--repo", repository, "--json", fields]
  }

  /// `gh pr view --json` output; nil when it isn't one pull request.
  public static func parse(_ data: Data) -> Page? {
    guard let item = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let number = (item["number"] as? NSNumber)?.intValue, let title = item["title"] as? String else { return nil }
    func string(_ key: String) -> String { item[key] as? String ?? "" }
    func int(_ key: String) -> Int { (item[key] as? NSNumber)?.intValue ?? 0 }
    func list(_ key: String) -> [[String: Any]] { item[key] as? [[String: Any]] ?? [] }
    let rollup = list("statusCheckRollup")
    return Page(
      number: number,
      title: title,
      body: string("body"),
      state: State(rawValue: string("state")) ?? .open,
      isDraft: item["isDraft"] as? Bool ?? false,
      author: login(item["author"]),
      createdAt: date(item["createdAt"]),
      head: string("headRefName"),
      headOid: string("headRefOid"),
      base: string("baseRefName"),
      additions: int("additions"),
      deletions: int("deletions"),
      changedFiles: int("changedFiles"),
      commits: list("commits").map(commit),
      reviews: list("reviews").compactMap(review),
      latestReviews: list("latestReviews").compactMap(review),
      comments: list("comments").map {
        Comment(author: login($0["author"]), body: $0["body"] as? String ?? "", createdAt: date($0["createdAt"]))
      },
      requestedReviewers: list("reviewRequests").compactMap { request in
        (request["login"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? request["name"] as? String
      },
      checks: PullRequests.Checks(rollup: rollup),
      checkList: rollup.compactMap(check),
      mergeable: PullRequests.PullRequest.Mergeable(rawValue: string("mergeable")) ?? .unknown,
      mergeState: MergeState(rawValue: string("mergeStateStatus")) ?? .unknown,
      reviewDecision: PullRequests.PullRequest.Review(rawValue: string("reviewDecision")) ?? .undecided,
      labels: list("labels").compactMap { label in
        (label["name"] as? String).map { Label(name: $0, color: label["color"] as? String ?? "") }
      },
      assignees: list("assignees").map { login($0) }.filter { !$0.isEmpty },
      autoMerge: (item["autoMergeRequest"] as? [String: Any]).flatMap {
        MergeMethod(rawValue: $0["mergeMethod"] as? String ?? "")
      },
      closingIssues: list("closingIssuesReferences").compactMap { ($0["number"] as? NSNumber)?.intValue },
      files: list("files").compactMap { file in
        (file["path"] as? String).map {
          File(path: $0, additions: (file["additions"] as? NSNumber)?.intValue ?? 0,
               deletions: (file["deletions"] as? NSNumber)?.intValue ?? 0, change: file["changeType"] as? String ?? "")
        }
      },
      isCrossRepository: item["isCrossRepository"] as? Bool ?? false
    )
  }

  /// The page's activity, oldest first. Commits in a row are one push (by the first one's author); the user's own
  /// pending review is a draft and isn't shown.
  public static func activity(_ page: Page) -> [Activity] {
    enum Entry {
      case commit(Commit)
      case review(Review)
      case comment(Comment)
    }
    var entries: [(date: Date, order: Int, entry: Entry)] = []
    for (index, commit) in page.commits.enumerated() {
      entries.append((commit.date ?? .distantPast, index, .commit(commit)))
    }
    for (index, review) in page.reviews.enumerated() where review.state != .pending {
      entries.append((review.submittedAt ?? .distantFuture, 10_000 + index, .review(review)))
    }
    for (index, comment) in page.comments.enumerated() {
      entries.append((comment.createdAt ?? .distantFuture, 20_000 + index, .comment(comment)))
    }
    entries.sort { ($0.date, $0.order) < ($1.date, $1.order) }
    var activity: [Activity] = []
    for item in entries {
      switch item.entry {
      case .commit(let commit):
        if case .pushed(let author, let commits) = activity.last {
          activity[activity.count - 1] = .pushed(author: author, commits: commits + [commit])
        } else {
          activity.append(.pushed(author: commit.author, commits: [commit]))
        }
      case .review(let review):
        activity.append(.reviewed(review))
      case .comment(let comment):
        activity.append(.commented(comment))
      }
    }
    return activity
  }

  /// An ISO 8601 date; nil for none, and for Go's zero time that some gh versions print.
  static func date(_ value: Any?) -> Date? {
    (value as? String)
      .flatMap { try? Date($0, strategy: .iso8601) }
      .flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil }
  }

  private static func login(_ object: Any?) -> String {
    (object as? [String: Any])?["login"] as? String ?? ""
  }

  private static func commit(_ item: [String: Any]) -> Commit {
    let first = (item["authors"] as? [[String: Any]])?.first
    let login = first?["login"] as? String ?? ""
    return Commit(oid: item["oid"] as? String ?? "", headline: item["messageHeadline"] as? String ?? "",
                  author: login.isEmpty ? (first?["name"] as? String ?? "") : login,
                  date: date(item["authoredDate"]) ?? date(item["committedDate"]))
  }

  private static func review(_ item: [String: Any]) -> Review? {
    guard let state = ReviewState(rawValue: item["state"] as? String ?? "") else { return nil }
    return Review(author: login(item["author"]), state: state, body: item["body"] as? String ?? "",
                  submittedAt: date(item["submittedAt"]), id: item["id"] as? String ?? "")
  }

  private static func check(_ item: [String: Any]) -> Check? {
    if let context = item["context"] as? String {
      // A commit status.
      let outcome: Check.Outcome
      switch item["state"] as? String ?? "" {
      case "SUCCESS": outcome = .passed
      case "FAILURE", "ERROR": outcome = .failed
      default: outcome = .running
      }
      return Check(name: context, outcome: outcome)
    }
    guard let name = item["name"] as? String else { return nil }
    guard (item["status"] as? String) == "COMPLETED" else { return Check(name: name, outcome: .running) }
    switch item["conclusion"] as? String ?? "" {
    case "SUCCESS", "NEUTRAL": return Check(name: name, outcome: .passed)
    case "SKIPPED": return Check(name: name, outcome: .skipped)
    default: return Check(name: name, outcome: .failed)
    }
  }
}
