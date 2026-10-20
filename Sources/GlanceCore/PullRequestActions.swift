import Foundation

/// The PR page's writes and lookups as gh arguments (spec 2026-10-07-pr-manager-design.md, "GitHub"): merge,
/// auto-merge, ready, update branch, check out, comment, close, edit the title, base, description, reviewers and
/// labels; the diff for Claude's read; the repository's branches, labels, users and issues; and how "Link an issue"
/// changes the description.
public enum PullRequestActions {
  public static func merge(_ number: Int, repository: String, method: PullRequestPage.MergeMethod,
                           auto: Bool = false) -> [String] {
    pr("merge", number, repository) + [method.flag] + (auto ? ["--auto"] : [])
  }

  public static func disableAutoMerge(_ number: Int, repository: String) -> [String] {
    pr("merge", number, repository) + ["--disable-auto"]
  }

  public static func markReady(_ number: Int, repository: String) -> [String] { pr("ready", number, repository) }
  public static func updateBranch(_ number: Int, repository: String) -> [String] { pr("update-branch", number, repository) }
  /// Runs in the project folder: gh checks the branch out there (and refuses over uncommitted changes).
  public static func checkout(_ number: Int, repository: String) -> [String] { pr("checkout", number, repository) }
  public static func close(_ number: Int, repository: String) -> [String] { pr("close", number, repository) }
  public static func diff(_ number: Int, repository: String) -> [String] { pr("diff", number, repository) }

  /// The comment's text goes to gh's stdin.
  public static func comment(_ number: Int, repository: String) -> [String] {
    pr("comment", number, repository) + ["--body-file", "-"]
  }

  /// The new description goes to gh's stdin.
  public static func editBody(_ number: Int, repository: String) -> [String] {
    pr("edit", number, repository) + ["--body-file", "-"]
  }

  /// One argument, so a title that starts with "-" isn't read as a flag.
  public static func editTitle(_ number: Int, repository: String, title: String) -> [String] {
    pr("edit", number, repository) + ["--title=" + title]
  }

  /// The branch it merges into (spec 2026-10-12-pr-sidebar-tabs-design.md, "Title and base").
  public static func editBase(_ number: Int, repository: String, base: String) -> [String] {
    pr("edit", number, repository) + ["--base=" + base]
  }

  /// The repository's branches, every page, a name a line.
  public static func branchList(repository: String) -> [String] {
    ["api", "repos/\(repository)/branches?per_page=100", "--paginate", "--jq", ".[].name"]
  }

  public static func parseBranches(_ data: Data) -> [String]? {
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }

  /// The base picker's rows: the branches whose name contains `filter` (case aside), but the pull request's own
  /// `head`; the current `base` first, then by name.
  public static func baseChoices(_ branches: [String], head: String, base: String, filter: String) -> [String] {
    let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
    let rows = Set(branches).filter { $0 != head && (query.isEmpty || $0.lowercased().contains(query)) }
    return rows.sorted { left, right in
      if (left == base) != (right == base) { return left == base }
      return left.localizedStandardCompare(right) == .orderedAscending
    }
  }

  public static func editReviewers(_ number: Int, repository: String, add: [String], remove: [String] = []) -> [String] {
    edit(number, repository, add: ("--add-reviewer", add), remove: ("--remove-reviewer", remove))
  }

  public static func editLabels(_ number: Int, repository: String, add: [String], remove: [String] = []) -> [String] {
    edit(number, repository, add: ("--add-label", add), remove: ("--remove-label", remove))
  }

  public static func labelList(repository: String) -> [String] {
    ["label", "list", "--repo", repository, "--json", "name,color", "--limit", "200"]
  }

  public static func parseLabels(_ data: Data) -> [PullRequestPage.Label]? {
    guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
    return items.compactMap { item in
      (item["name"] as? String).map { PullRequestPage.Label(name: $0, color: item["color"] as? String ?? "") }
    }
  }

  public struct Issue: Equatable, Sendable {
    public let number: Int
    public let title: String
    /// OPEN or CLOSED.
    public let state: String
    public let body: String
    public let author: String
    public let createdAt: Date?

    public init(number: Int, title: String, state: String, body: String, author: String, createdAt: Date?) {
      self.number = number
      self.title = title
      self.state = state
      self.body = body
      self.author = author
      self.createdAt = createdAt
    }
  }

  public static func issueView(_ number: Int, repository: String) -> [String] {
    ["issue", "view", String(number), "--repo", repository, "--json", "number,title,state,body,author,createdAt"]
  }

  public static func parseIssue(_ data: Data) -> Issue? {
    guard let item = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return issue(item)
  }

  public static func issueSearch(_ text: String, repository: String) -> [String] {
    ["issue", "list", "--repo", repository, "--search", text, "--state", "all", "--json", "number,title,state",
     "--limit", "8"]
  }

  public static func parseIssues(_ data: Data) -> [Issue]? {
    guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
    return items.compactMap(issue)
  }

  /// The people who can be asked to review (GraphQL; gh has no list command for them).
  public static func assignableUsersArguments(repository: String) -> [String]? {
    guard let parts = GitHubCLI.split(repository) else { return nil }
    let query = "query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { "
      + "assignableUsers(first: 100) { nodes { login } } } }"
    return GitHubCLI.graphQLArguments(query, variables: ["owner": .string(parts.owner), "name": .string(parts.name)])
  }

  public static func parseAssignableUsers(_ data: Data) -> [String]? {
    guard case .success(let payload) = GitHubCLI.graphQLData(data),
          let users = (payload["repository"] as? [String: Any])?["assignableUsers"] as? [String: Any],
          let nodes = users["nodes"] as? [[String: Any]] else { return nil }
    return nodes.compactMap { $0["login"] as? String }
  }

  /// The description with "Closes #N" added (GitHub links an issue a pull request closes only through its words),
  /// unless it already says it closes, fixes or resolves that issue.
  public static func body(_ body: String, closing issue: Int) -> String {
    let pattern = #"(?i)\b(close[sd]?|fix(e[sd])?|resolve[sd]?)\s+#"# + String(issue) + #"\b"#
    if body.range(of: pattern, options: .regularExpression) != nil { return body }
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Closes #\(issue)" : trimmed + "\n\nCloses #\(issue)"
  }

  /// gh's answer for a number that's an issue: the PR tab then shows the issue.
  public static func isNotAPullRequest(_ failure: PullRequests.Failure) -> Bool {
    if case .failed(let line) = failure { return line.contains("Could not resolve to a PullRequest") }
    return false
  }

  private static func pr(_ command: String, _ number: Int, _ repository: String) -> [String] {
    ["pr", command, String(number), "--repo", repository]
  }

  private static func edit(_ number: Int, _ repository: String, add: (flag: String, items: [String]),
                           remove: (flag: String, items: [String])) -> [String] {
    var arguments = pr("edit", number, repository)
    if !add.items.isEmpty { arguments += [add.flag, add.items.joined(separator: ",")] }
    if !remove.items.isEmpty { arguments += [remove.flag, remove.items.joined(separator: ",")] }
    return arguments
  }

  private static func issue(_ item: [String: Any]) -> Issue? {
    guard let number = (item["number"] as? NSNumber)?.intValue, let title = item["title"] as? String else { return nil }
    return Issue(number: number, title: title, state: item["state"] as? String ?? "", body: item["body"] as? String ?? "",
                 author: (item["author"] as? [String: Any])?["login"] as? String ?? "",
                 createdAt: PullRequestPage.date(item["createdAt"]))
  }
}
