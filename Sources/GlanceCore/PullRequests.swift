import Foundation

/// The PR manager's pull requests, read with the GitHub CLI and the account of `gh auth login` (spec
/// 2026-10-07-activity-strip-design.md).
public enum PullRequests {
  public struct PullRequest: Equatable, Sendable {
    public enum Review: String, Sendable {
      case approved = "APPROVED"
      case changesRequested = "CHANGES_REQUESTED"
      case required = "REVIEW_REQUIRED"
      /// No review rule on the branch, or no decision yet.
      case undecided = ""
    }

    public enum Mergeable: String, Sendable {
      case mergeable = "MERGEABLE"
      case conflicting = "CONFLICTING"
      /// GitHub hasn't worked it out yet.
      case unknown = "UNKNOWN"
    }

    public let number: Int
    public let title: String
    /// The author's login.
    public let author: String
    public let isDraft: Bool
    /// The branch it merges from.
    public let head: String
    /// The branch it merges into.
    public let base: String
    public let additions: Int
    public let deletions: Int
    public let changedFiles: Int
    public let review: Review
    public let checks: Checks
    public let mergeable: Mergeable
    public let url: String
    /// Nil until it's merged.
    public let mergedAt: Date?
    /// "owner/name": the board's repository, or the row's own on the All repositories board.
    public let repository: String

    public init(
      number: Int, title: String, author: String = "", isDraft: Bool = false, head: String = "", base: String = "",
      additions: Int = 0, deletions: Int = 0, changedFiles: Int = 0, review: Review = .undecided,
      checks: Checks = Checks(), mergeable: Mergeable = .unknown, url: String = "", mergedAt: Date? = nil,
      repository: String = ""
    ) {
      self.number = number
      self.title = title
      self.author = author
      self.isDraft = isDraft
      self.head = head
      self.base = base
      self.additions = additions
      self.deletions = deletions
      self.changedFiles = changedFiles
      self.review = review
      self.checks = checks
      self.mergeable = mergeable
      self.url = url
      self.mergedAt = mergedAt
      self.repository = repository
    }
  }

  /// A pull request's checks (check runs from Actions and apps, and commit statuses), counted as GitHub's merge box
  /// counts them.
  public struct Checks: Equatable, Sendable {
    public enum State: Sendable { case empty, pending, failing, passing }

    public let passed: Int
    public let failed: Int
    public let pending: Int

    public init(passed: Int = 0, failed: Int = 0, pending: Int = 0) {
      self.passed = passed
      self.failed = failed
      self.pending = pending
    }

    /// `statusCheckRollup` from `gh pr list --json`. Skipped and neutral runs count as passed, as on GitHub;
    /// cancelled, timed-out and action-required ones as failed.
    public init(rollup: [[String: Any]]) {
      var passed = 0, failed = 0, pending = 0
      for check in rollup {
        if let state = check["state"] as? String {
          // A commit status.
          switch state {
          case "SUCCESS": passed += 1
          case "FAILURE", "ERROR": failed += 1
          default: pending += 1
          }
        } else if (check["status"] as? String) != "COMPLETED" {
          // A check run still queued or running.
          pending += 1
        } else {
          switch (check["conclusion"] as? String) ?? "" {
          case "SUCCESS", "NEUTRAL", "SKIPPED": passed += 1
          default: failed += 1
          }
        }
      }
      self.init(passed: passed, failed: failed, pending: pending)
    }

    public var total: Int { passed + failed + pending }

    /// A failure outweighs a check still running.
    public var state: State { failed > 0 ? .failing : pending > 0 ? .pending : passed > 0 ? .passing : .empty }

    /// "14/14": passed of all, for a row's chip. Nil when there are no checks.
    public var summary: String? { total == 0 ? nil : "\(passed)/\(total)" }
  }

  /// The side bar's lists, one `gh pr list` each, and its tabs.
  public enum List: String, CaseIterable, Sendable {
    /// Open, with your review requested.
    case waitingOnYou
    /// Open and yours, drafts too.
    case yours
    /// Yours and merged, the newest few.
    case recentlyMerged
  }

  /// What the side bar shows.
  public struct Board: Equatable, Sendable {
    /// "owner/name".
    public let repository: String
    public let waitingOnYou: [PullRequest]
    public let yours: [PullRequest]
    /// Newest merge first.
    public let recentlyMerged: [PullRequest]

    public init(repository: String = "", waitingOnYou: [PullRequest], yours: [PullRequest], recentlyMerged: [PullRequest]) {
      self.repository = repository
      self.waitingOnYou = waitingOnYou
      self.yours = yours
      self.recentlyMerged = recentlyMerged.sorted { ($0.mergedAt ?? .distantPast) > ($1.mergedAt ?? .distantPast) }
    }

    public func pullRequests(_ list: List) -> [PullRequest] {
      switch list {
      case .waitingOnYou: waitingOnYou
      case .yours: yours
      case .recentlyMerged: recentlyMerged
      }
    }
  }

  /// What stands between a pull request and merging it.
  public enum Blocker: Equatable, Sendable {
    case draft
    case conflicts
    case checksFailing(Int)
    case changesRequested
    case checksPending(Int)
    case reviewRequired

    /// Needs someone to act, rather than waiting for CI or a reviewer.
    public var isHard: Bool {
      switch self {
      case .draft, .conflicts, .checksFailing, .changesRequested: true
      case .checksPending, .reviewRequired: false
      }
    }
  }

  public enum Failure: Error, Equatable, Sendable {
    /// No `gh` on this Mac.
    case notInstalled
    /// `gh` isn't signed in: the side bar's Sign in with GitHub.
    case signedOut
    /// The folder has no GitHub remote.
    case notGitHub
    /// Anything else, with the first line gh printed about it.
    case failed(String)

    /// What to tell the user.
    public var message: String {
      switch self {
      case .notInstalled: "Install the GitHub CLI: brew install gh"
      case .signedOut: "Sign in to GitHub from the Pull requests side bar."
      case .notGitHub: "This project isn't on GitHub."
      case .failed(let line): line
      }
    }
  }

  /// The fields each list asks `gh pr list --json` for.
  public static let fields = "number,title,author,isDraft,headRefName,baseRefName,additions,deletions,changedFiles,"
    + "reviewDecision,statusCheckRollup,mergeable,url,mergedAt"

  /// The `gh` arguments for one list of `repository` ("owner/name").
  public static func arguments(_ list: List, repository: String) -> [String] {
    let common = ["pr", "list", "--repo", repository, "--json", fields]
    switch list {
    case .waitingOnYou: return common + ["--state", "open", "--search", "review-requested:@me", "--limit", "30"]
    case .yours: return common + ["--state", "open", "--author", "@me", "--limit", "30"]
    case .recentlyMerged: return common + ["--state", "merged", "--author", "@me", "--limit", "5"]
    }
  }

  /// `gh pr list --json` output. Nil when it isn't a list (a half-read pipe, an error object).
  public static func parse(_ data: Data, repository: String = "") -> [PullRequest]? {
    guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
    return items.compactMap { pullRequest($0, repository: repository) }
  }

  private static func pullRequest(_ item: [String: Any], repository: String) -> PullRequest? {
    guard let number = (item["number"] as? NSNumber)?.intValue, let title = item["title"] as? String else { return nil }
    func int(_ key: String) -> Int { (item[key] as? NSNumber)?.intValue ?? 0 }
    func string(_ key: String) -> String { item[key] as? String ?? "" }
    // An open pull request's mergedAt is null, or Go's zero time in some gh versions.
    let mergedAt = (item["mergedAt"] as? String)
      .flatMap { try? Date($0, strategy: .iso8601) }
      .flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil }
    return PullRequest(
      number: number,
      title: title,
      author: (item["author"] as? [String: Any])?["login"] as? String ?? "",
      isDraft: item["isDraft"] as? Bool ?? false,
      head: string("headRefName"),
      base: string("baseRefName"),
      additions: int("additions"),
      deletions: int("deletions"),
      changedFiles: int("changedFiles"),
      review: PullRequest.Review(rawValue: string("reviewDecision")) ?? .undecided,
      checks: Checks(rollup: item["statusCheckRollup"] as? [[String: Any]] ?? []),
      mergeable: PullRequest.Mergeable(rawValue: string("mergeable")) ?? .unknown,
      url: string("url"),
      mergedAt: mergedAt,
      repository: repository
    )
  }

  /// What blocks a merge, worst first. Empty when nothing does.
  public static func blockers(_ pullRequest: PullRequest) -> [Blocker] {
    var blockers: [Blocker] = []
    if pullRequest.isDraft { blockers.append(.draft) }
    if pullRequest.mergeable == .conflicting { blockers.append(.conflicts) }
    if pullRequest.checks.failed > 0 { blockers.append(.checksFailing(pullRequest.checks.failed)) }
    if pullRequest.review == .changesRequested { blockers.append(.changesRequested) }
    if pullRequest.checks.pending > 0 { blockers.append(.checksPending(pullRequest.checks.pending)) }
    if pullRequest.review == .required { blockers.append(.reviewRequired) }
    return blockers
  }

  /// A row's second line: "#48 · mira-k · review requested", "#51 · feat/release → main", "#49 · draft",
  /// "#50 · changes requested", "#47 · merged".
  public static func subline(_ pullRequest: PullRequest, in list: List, showsRepository: Bool = false) -> String {
    let detail: String
    switch list {
    case .waitingOnYou:
      detail = pullRequest.author + " · review requested"
    case .yours:
      detail = pullRequest.isDraft ? "draft"
        : pullRequest.review == .changesRequested ? "changes requested"
        : pullRequest.head + " → " + pullRequest.base
    case .recentlyMerged:
      detail = "merged"
    }
    let line = "#\(pullRequest.number) · " + detail
    guard showsRepository, !pullRequest.repository.isEmpty else { return line }
    return (pullRequest.repository.split(separator: "/").last.map(String.init) ?? pullRequest.repository) + " · " + line
  }

  /// Whether a row passes the side bar's filter: its title or author contains the text, or its number starts with it
  /// ("#5", "51"). Case doesn't matter; an empty filter passes everything.
  public static func matches(_ pullRequest: PullRequest, filter: String) -> Bool {
    let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
    guard !query.isEmpty else { return true }
    let digits = query.hasPrefix("#") ? String(query.dropFirst()) : query
    if !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
      String(pullRequest.number).hasPrefix(digits) {
      return true
    }
    return pullRequest.title.lowercased().contains(query) || pullRequest.author.lowercased().contains(query)
  }

  /// "owner/name" of a github.com remote: https://github.com/o/r(.git), git@github.com:o/r(.git) or
  /// ssh://git@github.com(:22)/o/r(.git). Nil for anything else.
  public static func repository(remoteURL: String) -> String? {
    var rest = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
    for scheme in ["https://", "http://", "ssh://", "git://"] where rest.hasPrefix(scheme) {
      rest = String(rest.dropFirst(scheme.count))
    }
    // A user (git@) or a token before the host.
    if let at = rest.firstIndex(of: "@"), !rest[..<at].contains("/") {
      rest = String(rest[rest.index(after: at)...])
    }
    guard let separator = rest.firstIndex(where: { $0 == "/" || $0 == ":" }),
      ["github.com", "www.github.com"].contains(rest[..<separator].lowercased()) else { return nil }
    var path = String(rest[rest.index(after: separator)...])
    if path.hasSuffix("/") { path = String(path.dropLast()) }
    if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
    var parts = path.split(separator: "/")
    // ssh://git@github.com:22/o/r: the port.
    if parts.count == 3, parts[0].allSatisfy(\.isNumber) { parts.removeFirst() }
    guard parts.count == 2 else { return nil }
    return "\(parts[0])/\(parts[1])"
  }

  /// The repository a folder's pull requests are on, from `git remote -v`: the first of `repositories(remotes:)`.
  public static func repository(remotes output: String) -> String? {
    repositories(remotes: output).first
  }

  /// Every GitHub repository among a folder's remotes (`git remote -v`), each once whatever its case, in gh's order:
  /// upstream, github, origin, then the others as listed. A fork's clone lists the original and the fork.
  public static func repositories(remotes output: String) -> [String] {
    var found: [(name: String, repository: String, offset: Int)] = []
    for (offset, line) in output.split(separator: "\n").enumerated() {
      let columns = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
      guard columns.count >= 2, let repo = repository(remoteURL: String(columns[1])) else { continue }
      found.append((name: String(columns[0]), repository: repo, offset: offset))
    }
    let rank = ["upstream": 0, "github": 1, "origin": 2]
    var seen: Set<String> = []
    return found
      .sorted { (rank[$0.name] ?? 3, $0.offset) < (rank[$1.name] ?? 3, $1.offset) }
      .compactMap { seen.insert($0.repository.lowercased()).inserted ? $0.repository : nil }
  }

  /// Where `gh` is. An app opened from the Dock doesn't get the shell's PATH, so look where installers put it.
  public static func executable(
    home: String = NSHomeDirectory(),
    isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
  ) -> String? {
    let candidates = [
      "/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/opt/local/bin/gh", home + "/.local/bin/gh",
      home + "/.nix-profile/bin/gh", "/run/current-system/sw/bin/gh", "/usr/bin/gh",
    ]
    return candidates.first(where: isExecutable)
  }

  /// The side bar's lists for `repository` ("owner/name"), with `gh` at `gh` (see `executable`): one gh call per list,
  /// so call it off the main thread.
  public static func board(repository: String, gh: String?) -> Result<Board, Failure> {
    guard let gh else { return .failure(.notInstalled) }
    var lists: [List: [PullRequest]] = [:]
    for list in List.allCases {
      switch GitHubCLI.run(gh, arguments(list, repository: repository)) {
      case .failure(let failure):
        return .failure(failure)
      case .success(let output):
        guard let pullRequests = parse(output, repository: repository) else { return .failure(.failed("gh printed a list Glance can't read")) }
        lists[list] = pullRequests
      }
    }
    return .success(Board(
      repository: repository, waitingOnYou: lists[.waitingOnYou] ?? [], yours: lists[.yours] ?? [],
      recentlyMerged: lists[.recentlyMerged] ?? []
    ))
  }

  /// The repository the side bar shows (spec 2026-10-08-pr-repositories-design.md, "Which repository shows"): the one
  /// picked in the picker, else the tab's project when it's on GitHub. Nil shows the picker's list.
  public static func shownRepository(picked: String?, tabProject: String?) -> String? {
    picked ?? tabProject
  }

  /// The side bar's pick for every repository on the account (spec 2026-10-08-pr-ask-lists-design.md, "Stage 2").
  public static let allRepositories = "*"

  /// Three searches in one GraphQL call; each node has the fields `gh pr list --json` gives a row, plus its repository.
  public static let accountQuery = """
    query($waiting: String!, $yours: String!, $merged: String!) {
      waiting: search(query: $waiting, type: ISSUE, first: 30) { nodes { ...row } }
      yours: search(query: $yours, type: ISSUE, first: 30) { nodes { ...row } }
      merged: search(query: $merged, type: ISSUE, first: 5) { nodes { ...row } }
    }
    fragment row on PullRequest {
      number title isDraft url headRefName baseRefName additions deletions changedFiles reviewDecision mergeable mergedAt
      author { login } repository { nameWithOwner }
      commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes { __typename
        ... on CheckRun { status conclusion } ... on StatusContext { state } } } } } } }
    }
    """

  public static func accountArguments() -> [String] {
    ["api", "graphql", "-f", "query=" + accountQuery,
     "-f", "waiting=is:pr is:open archived:false review-requested:@me sort:updated-desc",
     "-f", "yours=is:pr is:open archived:false author:@me sort:updated-desc",
     "-f", "merged=is:pr is:merged author:@me sort:updated-desc"]
  }

  /// The account searches' answer as a board of `allRepositories`. Nil when it isn't one (an errors object).
  public static func parseAccount(_ data: Data) -> Board? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let searches = object["data"] as? [String: Any] else { return nil }
    func rows(_ name: String) -> [PullRequest] {
      let nodes = (searches[name] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
      return nodes.compactMap { node in
        var item = node
        let commit = ((node["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?.last?["commit"]
          as? [String: Any]
        let contexts = ((commit?["statusCheckRollup"] as? [String: Any])?["contexts"] as? [String: Any])?["nodes"]
        item["statusCheckRollup"] = contexts as? [[String: Any]] ?? []
        let repository = (node["repository"] as? [String: Any])?["nameWithOwner"] as? String ?? ""
        return pullRequest(item, repository: repository)
      }
    }
    return Board(repository: allRepositories, waitingOnYou: rows("waiting"), yours: rows("yours"),
                 recentlyMerged: rows("merged"))
  }

  /// The All repositories board, with `gh` at `gh`: one call, so call it off the main thread.
  public static func accountBoard(gh: String?) -> Result<Board, Failure> {
    guard let gh else { return .failure(.notInstalled) }
    switch GitHubCLI.run(gh, accountArguments()) {
    case .failure(let failure): return .failure(failure)
    case .success(let output):
      guard let board = parseAccount(output) else { return .failure(.failed("gh printed a list Glance can't read")) }
      return .success(board)
    }
  }
}
