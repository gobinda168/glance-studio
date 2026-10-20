import Foundation

/// The work Glance sees, turned into status suggestions (spec "Signals, suggestions, policy"). Only the last
/// `window` of git and pull request activity counts, so a first scan doesn't dig up last week.
public enum TicketSignals {
  public static let window: TimeInterval = 2 * 86_400

  public struct Commit: Equatable, Sendable {
    public var hash: String
    public var subject: String
    public var repository: String?
    public var date: Date

    public init(hash: String, subject: String, repository: String?, date: Date) {
      self.hash = hash
      self.subject = subject
      self.repository = repository
      self.date = date
    }
  }

  public struct Branch: Equatable, Sendable {
    public var name: String
    public var repository: String?
    public var date: Date

    public init(name: String, repository: String?, date: Date) {
      self.name = name
      self.repository = repository
      self.date = date
    }
  }

  public struct PullRequest: Equatable, Sendable {
    public enum State: String, Sendable { case open, merged }

    public var repository: String
    public var number: Int
    public var title: String
    public var body: String
    public var branch: String
    public var url: URL?
    public var state: State
    /// Opened (open) or merged (merged).
    public var date: Date

    public init(repository: String, number: Int, title: String, body: String, branch: String, url: URL?,
                state: State, date: Date) {
      self.repository = repository
      self.number = number
      self.title = title
      self.body = body
      self.branch = branch
      self.url = url
      self.state = state
      self.date = date
    }
  }

  /// → in progress, the newest evidence per ticket.
  public static func git(commits: [Commit], branches: [Branch], tickets: [Ticket], now: Date) -> [Suggestion] {
    let since = now.addingTimeInterval(-window)
    var best: [String: Suggestion] = [:]
    func offer(_ suggestion: Suggestion) {
      if let old = best[suggestion.ticketID], old.date >= suggestion.date { return }
      best[suggestion.ticketID] = suggestion
    }
    for commit in commits where commit.date >= since {
      for ticket in TicketKeys.mentioned(in: commit.subject, tickets: tickets, repository: commit.repository) {
        offer(Suggestion(ticketID: ticket.id, signal: .git, target: .inProgress,
                         evidence: "Commit \(commit.hash.prefix(7)) · \(commit.subject)",
                         evidenceID: "commit:\(commit.hash)", link: nil, date: commit.date))
      }
    }
    for branch in branches where branch.date >= since {
      for ticket in TicketKeys.mentioned(in: branch.name, tickets: tickets, repository: branch.repository) {
        offer(Suggestion(ticketID: ticket.id, signal: .git, target: .inProgress, evidence: "Branch \(branch.name)",
                         evidenceID: "branch:\(branch.repository ?? ""):\(branch.name)", link: nil, date: branch.date))
      }
    }
    return best.values.sorted { $0.date > $1.date }
  }

  /// Opened → in review, merged → done; a merge beats an opening, then the newest.
  public static func pullRequests(_ pullRequests: [PullRequest], tickets: [Ticket], now: Date) -> [Suggestion] {
    let since = now.addingTimeInterval(-window)
    var best: [String: Suggestion] = [:]
    for pr in pullRequests where pr.date >= since {
      let merged = pr.state == .merged
      let text = [pr.title, pr.branch, pr.body].joined(separator: "\n")
      for ticket in TicketKeys.mentioned(in: text, tickets: tickets, repository: pr.repository) {
        let suggestion = Suggestion(
          ticketID: ticket.id, signal: merged ? .prMerged : .prOpened, target: merged ? .done : .review,
          evidence: "PR #\(pr.number) \(merged ? "merged" : "opened") · \(pr.title)",
          evidenceID: "pr:\(pr.repository)#\(pr.number):\(pr.state.rawValue)", link: pr.url, date: pr.date)
        if let old = best[ticket.id] {
          if old.signal == .prMerged && !merged { continue }
          if old.signal == suggestion.signal && old.date >= suggestion.date { continue }
        }
        best[ticket.id] = suggestion
      }
    }
    return best.values.sorted { $0.date > $1.date }
  }

  /// In progress with nothing seen for `days` days (activity or the tracker's own update, whichever is later).
  public static func stale(tickets: [Ticket], activity: [String: Date], now: Date, days: Int) -> [Suggestion] {
    guard days > 0 else { return [] }
    return tickets.compactMap { ticket in
      guard ticket.statusCategory == .inProgress,
            let last = [activity[ticket.id], ticket.updated].compactMap({ $0 }).max() else { return nil }
      let quiet = now.timeIntervalSince(last)
      guard quiet >= Double(days) * 86_400 else { return nil }
      return Suggestion(ticketID: ticket.id, signal: .stale, target: nil,
                        evidence: "No activity for \(Int(quiet / 86_400)) days",
                        evidenceID: "stale:\(Int(last.timeIntervalSince1970))", link: ticket.url, date: now)
    }
  }

  /// A Claude Code session whose prompts or branch name a ticket → in progress.
  public static func session(prompts: [String], branch: String?, repository: String?, file: String,
                             tickets: [Ticket], at date: Date) -> [Suggestion] {
    var found: [(Ticket, String)] = []
    func add(_ text: String, _ why: String) {
      for ticket in TicketKeys.mentioned(in: text, tickets: tickets, repository: repository)
      where !found.contains(where: { $0.0.id == ticket.id }) {
        found.append((ticket, why))
      }
    }
    prompts.forEach { add($0, $0) }
    if let branch { add(branch, "branch \(branch)") }
    return found.map { ticket, why in
      Suggestion(ticketID: ticket.id, signal: .session, target: .inProgress,
                 evidence: "Claude session · " + String(why.prefix(60)), evidenceID: "session:\(file)", link: nil,
                 date: date)
    }
  }

  // MARK: git and GitHub

  /// The 30 most recently committed local branches: "name\u{1f}date" per line.
  public static func branchArguments(root: String) -> [String] {
    ["-C", root, "for-each-ref", "--sort=-committerdate", "--count=30",
     "--format=%(refname:short)%1f%(committerdate:iso8601-strict)", "refs/heads"]
  }

  public static func branches(_ output: String, repository: String?) -> [Branch] {
    output.split(separator: "\n").compactMap { line in
      let fields = line.split(separator: "\u{1f}", omittingEmptySubsequences: false)
      guard fields.count == 2, let date = TicketPrompts.date(String(fields[1])) else { return nil }
      return Branch(name: String(fields[0]), repository: repository, date: date)
    }
  }

  static let pullRequestQuery = """
    query($open: String!, $merged: String!) {
      open: search(type: ISSUE, query: $open, first: 50) { nodes { ...pr } }
      merged: search(type: ISSUE, query: $merged, first: 50) { nodes { ...pr } }
    }
    fragment pr on PullRequest {
      number title body url headRefName createdAt mergedAt repository { nameWithOwner }
    }
    """

  /// The user's open pull requests updated, and merged ones merged, within the window (a day more: GitHub is UTC).
  public static func pullRequestArguments(now: Date) -> [String] {
    let since = TicketPrompts.day(now.addingTimeInterval(-window - 86_400))
    return GitHubCLI.graphQLArguments(pullRequestQuery, variables: [
      "open": .string("is:pr author:@me is:open updated:>=\(since)"),
      "merged": .string("is:pr author:@me merged:>=\(since)"),
    ])
  }

  /// From the GraphQL response's `data`.
  public static func pullRequests(from data: [String: Any]) -> [PullRequest] {
    func nodes(_ alias: String) -> [[String: Any]] {
      (data[alias] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
    }
    func read(_ node: [String: Any], _ state: PullRequest.State) -> PullRequest? {
      guard let number = node["number"] as? Int, let title = node["title"] as? String,
            let repository = (node["repository"] as? [String: Any])?["nameWithOwner"] as? String,
            let date = TicketPrompts.date(state == .merged ? node["mergedAt"] : node["createdAt"]) else { return nil }
      return PullRequest(repository: repository, number: number, title: title, body: node["body"] as? String ?? "",
                         branch: node["headRefName"] as? String ?? "",
                         url: (node["url"] as? String).flatMap(URL.init(string:)), state: state, date: date)
    }
    return nodes("open").compactMap { read($0, .open) } + nodes("merged").compactMap { read($0, .merged) }
  }

  /// The repository whose folder holds `folder` (the deepest match).
  public static func repository(for folder: String, in folders: [String: String]) -> String? {
    folders.filter { _, root in
      let base = root.hasSuffix("/") ? String(root.dropLast()) : root
      return folder == base || folder.hasPrefix(base + "/")
    }
    .max { $0.value.count < $1.value.count }?.key
  }
}
