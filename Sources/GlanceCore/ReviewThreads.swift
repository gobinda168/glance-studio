import Foundation

/// A pull request's review threads (GraphQL; `gh pr view` doesn't have them) and the rules the PR manager sorts them
/// by (spec 2026-10-07-pr-manager-design.md, "Rules"): blocking, optional, from a bot, waiting on you.
public enum ReviewThreads {
  public struct Comment: Equatable, Sendable {
    public let id: String
    /// REST's id, for replies.
    public let databaseID: Int
    public let author: String
    public let isBot: Bool
    public let body: String
    public let createdAt: Date?
    /// The state of the review it was posted in.
    public let reviewState: PullRequestPage.ReviewState?
    /// Still in its author's pending review: only they see it until they submit.
    public let isPending: Bool
    /// The viewer wrote it.
    public let viewerDidAuthor: Bool
    public let viewerCanUpdate: Bool
    public let viewerCanDelete: Bool
    /// The id of the review it was posted in.
    public let reviewID: String?

    public init(id: String, databaseID: Int, author: String, isBot: Bool, body: String, createdAt: Date?,
                reviewState: PullRequestPage.ReviewState?, isPending: Bool = false, viewerDidAuthor: Bool = false,
                viewerCanUpdate: Bool = false, viewerCanDelete: Bool = false, reviewID: String? = nil) {
      self.id = id
      self.databaseID = databaseID
      self.author = author
      self.isBot = isBot
      self.body = body
      self.createdAt = createdAt
      self.reviewState = reviewState
      self.isPending = isPending
      self.viewerDidAuthor = viewerDidAuthor
      self.viewerCanUpdate = viewerCanUpdate
      self.viewerCanDelete = viewerCanDelete
      self.reviewID = reviewID
    }
  }

  public struct Thread: Equatable, Sendable {
    public enum Side: String, Sendable { case left = "LEFT", right = "RIGHT" }

    public let id: String
    public let isResolved: Bool
    public let isOutdated: Bool
    public let path: String
    /// Nil once the line is gone from the diff (an outdated thread).
    public let line: Int?
    public let startLine: Int?
    public let side: Side
    public let resolvedBy: String?
    public let comments: [Comment]
    /// The line it was written on, before later pushes moved or removed it.
    public let originalLine: Int?
    /// The side of a range's first line.
    public let startSide: Side?
    /// On the file as a whole, not a line.
    public let isFileLevel: Bool
    public let viewerCanReply: Bool
    public let viewerCanResolve: Bool
    public let viewerCanUnresolve: Bool

    public init(id: String, isResolved: Bool, isOutdated: Bool, path: String, line: Int?, startLine: Int?, side: Side,
                resolvedBy: String?, comments: [Comment], originalLine: Int? = nil, startSide: Side? = nil,
                isFileLevel: Bool = false, viewerCanReply: Bool = false, viewerCanResolve: Bool = false,
                viewerCanUnresolve: Bool = false) {
      self.id = id
      self.isResolved = isResolved
      self.isOutdated = isOutdated
      self.path = path
      self.line = line
      self.startLine = startLine
      self.side = side
      self.resolvedBy = resolvedBy
      self.comments = comments
      self.originalLine = originalLine
      self.startSide = startSide
      self.isFileLevel = isFileLevel
      self.viewerCanReply = viewerCanReply
      self.viewerCanResolve = viewerCanResolve
      self.viewerCanUnresolve = viewerCanUnresolve
    }

    /// A new thread in the viewer's pending review: every comment in it is pending.
    public var isPending: Bool { !comments.isEmpty && comments.allSatisfy(\.isPending) }
  }

  public enum Severity: Equatable, Sendable { case blocking, optional, normal }

  /// Read from the first comment's first line: an optional marker wins ("nit", "optional", "minor", "non-blocking",
  /// 🟡), then a blocking one (🛑 🔴 ❗, "blocking", "blocker", "important", "requirement", "must fix"); else a review
  /// that requested changes blocks.
  public static func severity(_ thread: Thread) -> Severity {
    guard let first = thread.comments.first else { return .normal }
    let head = first.body.split(whereSeparator: \.isNewline).first.map { $0.lowercased() } ?? ""
    let words = Set(head.split(whereSeparator: { !$0.isLetter }).map(String.init))
    if head.contains("🟡") || head.contains("non-blocking") || !words.isDisjoint(with: ["nit", "nitpick", "optional", "minor"]) {
      return .optional
    }
    if head.contains("🛑") || head.contains("🔴") || head.contains("❗") || head.contains("must fix")
      || head.contains("must-fix") || !words.isDisjoint(with: ["blocking", "blocker", "important", "requirement"]) {
      return .blocking
    }
    return first.reviewState == .changesRequested ? .blocking : .normal
  }

  public static func isFromBot(_ thread: Thread) -> Bool {
    guard let first = thread.comments.first else { return false }
    return first.isBot || first.author.hasSuffix("[bot]")
  }

  /// Unresolved, and someone other than `viewer` had the last word, on the viewer's own pull request (`author`) or one
  /// they wrote in.
  public static func isWaiting(_ thread: Thread, on viewer: String, author: String) -> Bool {
    guard !thread.isResolved, let last = thread.comments.last, last.author != viewer else { return false }
    return author == viewer || thread.comments.contains { $0.author == viewer }
  }

  /// What the PR page reads besides `gh pr view`.
  public struct PageExtras: Equatable, Sendable {
    public let viewer: String
    /// The pull request's GraphQL id, for mutations.
    public let pullRequestID: String
    /// The base branch's required approvals, when its rule is readable.
    public let requiredApprovals: Int?
    public var threads: [Thread]
    /// The files the viewer marked viewed (a file changed since it was viewed isn't).
    public var viewed: Set<String>
    /// The viewer's pending review, and how many comments it holds.
    public var pendingReviewID: String?
    public var pendingCount: Int
    /// Where the next pages of files and threads start, while there are more.
    public var moreFiles: String?
    public var moreThreads: String?

    public init(viewer: String, pullRequestID: String, requiredApprovals: Int?, threads: [Thread],
                viewed: Set<String> = [], pendingReviewID: String? = nil, pendingCount: Int = 0,
                moreFiles: String? = nil, moreThreads: String? = nil) {
      self.viewer = viewer
      self.pullRequestID = pullRequestID
      self.requiredApprovals = requiredApprovals
      self.threads = threads
      self.viewed = viewed
      self.pendingReviewID = pendingReviewID
      self.pendingCount = pendingCount
      self.moreFiles = moreFiles
      self.moreThreads = moreThreads
    }

    /// Unresolved threads marked blocking.
    public var blocking: [Thread] { threads.filter { !$0.isResolved && ReviewThreads.severity($0) == .blocking } }
    public var unresolvedCount: Int { threads.filter { !$0.isResolved }.count }
  }

  /// A review thread's fields, as the PR page and the Files page read them.
  static let threadFields = "id isResolved isOutdated path line startLine originalLine diffSide startDiffSide "
    + "subjectType resolvedBy { login } viewerCanReply viewerCanResolve viewerCanUnresolve "
    + "comments(first: 50) { nodes { id databaseId body createdAt state viewerDidAuthor viewerCanUpdate "
    + "viewerCanDelete author { login __typename } pullRequestReview { id state } } }"

  /// The viewer, the pull request's id and required approvals, the viewer's pending review, the first 100 files'
  /// viewed state and the first 100 threads.
  public static let pageQuery = """
    query($owner: String!, $name: String!, $number: Int!) { viewer { login } repository(owner: $owner, name: $name) { \
    pullRequest(number: $number) { id baseRef { branchProtectionRule { requiredApprovingReviewCount } } \
    reviews(states: PENDING, first: 1) { nodes { id comments(first: 1) { totalCount } } } \
    files(first: 100) { pageInfo { hasNextPage endCursor } nodes { path viewerViewedState } } \
    reviewThreads(first: 100) { pageInfo { hasNextPage endCursor } nodes { \(threadFields) } } } } }
    """

  /// The next 100 files' viewed state, after `$after`.
  public static let moreFilesQuery = """
    query($owner: String!, $name: String!, $number: Int!, $after: String!) { repository(owner: $owner, name: $name) { \
    pullRequest(number: $number) { files(first: 100, after: $after) { pageInfo { hasNextPage endCursor } \
    nodes { path viewerViewedState } } } } }
    """

  /// The next 100 threads, after `$after`.
  public static let moreThreadsQuery = """
    query($owner: String!, $name: String!, $number: Int!, $after: String!) { repository(owner: $owner, name: $name) { \
    pullRequest(number: $number) { reviewThreads(first: 100, after: $after) { pageInfo { hasNextPage endCursor } \
    nodes { \(threadFields) } } } } }
    """

  public static func pageArguments(repository: String, number: Int) -> [String]? {
    guard let parts = GitHubCLI.split(repository) else { return nil }
    return GitHubCLI.graphQLArguments(pageQuery, variables: [
      "owner": .string(parts.owner), "name": .string(parts.name), "number": .int(number),
    ])
  }

  public static func parsePage(_ data: Data) -> PageExtras? {
    guard case .success(let payload) = GitHubCLI.graphQLData(data),
          let pullRequest = (payload["repository"] as? [String: Any])?["pullRequest"] as? [String: Any] else { return nil }
    let rule = ((pullRequest["baseRef"] as? [String: Any])?["branchProtectionRule"] as? [String: Any])
    let pending = nodes(pullRequest["reviews"]).first
    return PageExtras(
      viewer: (payload["viewer"] as? [String: Any])?["login"] as? String ?? "",
      pullRequestID: pullRequest["id"] as? String ?? "",
      requiredApprovals: (rule?["requiredApprovingReviewCount"] as? NSNumber)?.intValue,
      threads: nodes(pullRequest["reviewThreads"]).compactMap(thread),
      viewed: viewedPaths(pullRequest["files"]),
      pendingReviewID: pending?["id"] as? String,
      pendingCount: ((pending?["comments"] as? [String: Any])?["totalCount"] as? NSNumber)?.intValue ?? 0,
      moreFiles: nextCursor(pullRequest["files"]),
      moreThreads: nextCursor(pullRequest["reviewThreads"]))
  }

  // MARK: Further pages

  /// A page after the first 100 files: the viewed ones, and where the next page starts.
  public struct MoreFiles: Equatable, Sendable {
    public let viewed: Set<String>
    public let next: String?
  }

  /// A page after the first 100 threads, and where the next page starts.
  public struct MoreThreads: Equatable, Sendable {
    public let threads: [Thread]
    public let next: String?
  }

  /// `moreFilesQuery` or `moreThreadsQuery` for `repository` ("owner/name"), after the cursor `after`.
  public static func moreArguments(_ query: String, repository: String, number: Int, after: String) -> [String]? {
    guard let parts = GitHubCLI.split(repository) else { return nil }
    return GitHubCLI.graphQLArguments(query, variables: [
      "owner": .string(parts.owner), "name": .string(parts.name), "number": .int(number), "after": .string(after),
    ])
  }

  public static func parseMoreFiles(_ data: Data) -> MoreFiles? {
    guard let files = pullRequest(data)?["files"] else { return nil }
    return MoreFiles(viewed: viewedPaths(files), next: nextCursor(files))
  }

  public static func parseMoreThreads(_ data: Data) -> MoreThreads? {
    guard let threads = pullRequest(data)?["reviewThreads"] else { return nil }
    return MoreThreads(threads: nodes(threads).compactMap(thread), next: nextCursor(threads))
  }

  private static func pullRequest(_ data: Data) -> [String: Any]? {
    guard case .success(let payload) = GitHubCLI.graphQLData(data) else { return nil }
    return (payload["repository"] as? [String: Any])?["pullRequest"] as? [String: Any]
  }

  /// The paths of a files connection that the viewer viewed (DISMISSED means changed since: not viewed).
  private static func viewedPaths(_ connection: Any?) -> Set<String> {
    Set(nodes(connection).compactMap { $0["viewerViewedState"] as? String == "VIEWED" ? $0["path"] as? String : nil })
  }

  /// Where a connection's next page starts; nil on its last.
  private static func nextCursor(_ connection: Any?) -> String? {
    guard let info = (connection as? [String: Any])?["pageInfo"] as? [String: Any],
          info["hasNextPage"] as? Bool == true else { return nil }
    return info["endCursor"] as? String
  }

  // MARK: The Files page

  /// Where a thread sits in a file's diff: a side, and a line number on it.
  public struct Anchor: Hashable, Sendable {
    public let side: Thread.Side
    public let line: Int

    public init(side: Thread.Side, line: Int) {
      self.side = side
      self.line = line
    }
  }

  /// A file's threads as the Files page lays them out.
  public struct Placement: Equatable, Sendable {
    /// Under their line.
    public var anchored: [Anchor: [Thread]] = [:]
    /// On the file as a whole, at its top.
    public var fileLevel: [Thread] = []
    /// Their line is gone from the diff: folded at the file's top.
    public var outdated: [Thread] = []

    public init() {}
  }

  /// `path`'s threads in `file`'s diff: under the line they're on (a context line has both sides' numbers), on the
  /// file, or folded as outdated when GitHub says so or their line isn't in the diff.
  public static func placement(_ threads: [Thread], path: String, file: PullRequestDiff.File) -> Placement {
    var anchors: Set<Anchor> = []
    for line in file.hunks.flatMap(\.lines) {
      if let old = line.old { anchors.insert(Anchor(side: .left, line: old)) }
      if let new = line.new { anchors.insert(Anchor(side: .right, line: new)) }
    }
    var placement = Placement()
    for thread in threads where thread.path == path {
      if thread.isFileLevel {
        placement.fileLevel.append(thread)
      } else if !thread.isOutdated, let line = thread.line, anchors.contains(Anchor(side: thread.side, line: line)) {
        placement.anchored[Anchor(side: thread.side, line: line), default: []].append(thread)
      } else {
        placement.outdated.append(thread)
      }
    }
    return placement
  }

  /// Each file's open threads (unresolved; pending ones too), for the side bar.
  public static func openCounts(_ threads: [Thread]) -> [String: Int] {
    threads.filter { !$0.isResolved }.reduce(into: [:]) { $0[$1.path, default: 0] += 1 }
  }

  /// A suggested change in a comment: the words around it and the lines it would put in place of the thread's.
  public struct Suggestion: Equatable, Sendable {
    public let before: String
    public let lines: [String]
    public let after: String
  }

  /// The first ```suggestion block in `body`, whatever its line endings; nil without one or without its closing fence.
  public static func suggestion(in body: String) -> Suggestion? {
    let lines = body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    guard let open = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "```suggestion" }),
          let close = lines[(open + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "```" })
    else { return nil }
    return Suggestion(
      before: lines[..<open].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
      lines: Array(lines[(open + 1)..<close]),
      after: lines[(close + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// A thread count for the side bar's rows and the Review comments row.
  public struct Summary: Equatable, Sendable {
    public let unresolved: Int
    public let blocking: Int

    public init(unresolved: Int, blocking: Int) {
      self.unresolved = unresolved
      self.blocking = blocking
    }
  }

  /// Unresolved threads and the blocking ones among them. The viewer's own pending comments aren't counted: nobody sees
  /// them until their review is sent.
  public static func summary(_ threads: [Thread]) -> Summary {
    let open = threads.filter { !$0.isResolved && !$0.isPending }
    return Summary(unresolved: open.count, blocking: open.filter { severity($0) == .blocking }.count)
  }

  /// Every listed pull request's threads by number, and who's reading them (Waiting on you needs the viewer).
  public struct BoardThreads: Equatable, Sendable {
    public let viewer: String
    public let threads: [Int: [Thread]]

    public init(viewer: String, threads: [Int: [Thread]]) {
      self.viewer = viewer
      self.threads = threads
    }
  }

  /// One query for every listed pull request's threads, whole (spec: "List and inbox"): the side bar's counts, the
  /// Review comments row and the inbox all read it. It takes the first 100 threads and their first 50 comments.
  public static func boardQuery(numbers: [Int]) -> String {
    let fields = "reviewThreads(first: 100) { nodes { \(threadFields) } }"
    let aliases = numbers.map { "pr\($0): pullRequest(number: \($0)) { \(fields) }" }.joined(separator: " ")
    return "query($owner: String!, $name: String!) { viewer { login } "
      + "repository(owner: $owner, name: $name) { \(aliases) } }"
  }

  public static func boardArguments(repository: String, numbers: [Int]) -> [String]? {
    guard !numbers.isEmpty, let parts = GitHubCLI.split(repository) else { return nil }
    return GitHubCLI.graphQLArguments(boardQuery(numbers: numbers), variables: [
      "owner": .string(parts.owner), "name": .string(parts.name),
    ])
  }

  public static func parseBoard(_ data: Data) -> BoardThreads? {
    guard case .success(let payload) = GitHubCLI.graphQLData(data),
          let repository = payload["repository"] as? [String: Any] else { return nil }
    var threads: [Int: [Thread]] = [:]
    for (key, value) in repository {
      guard key.hasPrefix("pr"), let number = Int(key.dropFirst(2)), let pullRequest = value as? [String: Any] else {
        continue
      }
      threads[number] = nodes(pullRequest["reviewThreads"]).compactMap(thread)
    }
    return BoardThreads(viewer: (payload["viewer"] as? [String: Any])?["login"] as? String ?? "", threads: threads)
  }

  private static func nodes(_ connection: Any?) -> [[String: Any]] {
    (connection as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
  }

  private static func thread(_ item: [String: Any]) -> Thread? {
    let comments = nodes(item["comments"]).map { comment -> Comment in
      let author = comment["author"] as? [String: Any]
      let review = comment["pullRequestReview"] as? [String: Any]
      return Comment(
        id: comment["id"] as? String ?? "",
        databaseID: (comment["databaseId"] as? NSNumber)?.intValue ?? 0,
        author: author?["login"] as? String ?? "",
        isBot: author?["__typename"] as? String == "Bot",
        body: comment["body"] as? String ?? "",
        createdAt: PullRequestPage.date(comment["createdAt"]),
        reviewState: (review?["state"] as? String).flatMap(PullRequestPage.ReviewState.init(rawValue:)),
        isPending: comment["state"] as? String == "PENDING",
        viewerDidAuthor: comment["viewerDidAuthor"] as? Bool ?? false,
        viewerCanUpdate: comment["viewerCanUpdate"] as? Bool ?? false,
        viewerCanDelete: comment["viewerCanDelete"] as? Bool ?? false,
        reviewID: review?["id"] as? String)
    }
    return Thread(
      id: item["id"] as? String ?? "",
      isResolved: item["isResolved"] as? Bool ?? false,
      isOutdated: item["isOutdated"] as? Bool ?? false,
      path: item["path"] as? String ?? "",
      line: (item["line"] as? NSNumber)?.intValue,
      startLine: (item["startLine"] as? NSNumber)?.intValue,
      side: Thread.Side(rawValue: item["diffSide"] as? String ?? "") ?? .right,
      resolvedBy: (item["resolvedBy"] as? [String: Any])?["login"] as? String,
      comments: comments,
      originalLine: (item["originalLine"] as? NSNumber)?.intValue,
      startSide: (item["startDiffSide"] as? String).flatMap(Thread.Side.init(rawValue:)),
      isFileLevel: item["subjectType"] as? String == "FILE",
      viewerCanReply: item["viewerCanReply"] as? Bool ?? false,
      viewerCanResolve: item["viewerCanResolve"] as? Bool ?? false,
      viewerCanUnresolve: item["viewerCanUnresolve"] as? Bool ?? false)
  }
}
