import Foundation

/// The Checks page (spec 2026-10-07-pr-manager-design.md, "Pages → Checks"): `gh pr checks --json` with each check's
/// workflow, times and where it ran, grouped failing, running, passing and skipped. GitHub is read through gh, so
/// nothing here opens github.com.
public enum PullRequestChecks {
  public typealias Outcome = PullRequestPage.Check.Outcome

  /// Where a check ran, read from its link.
  public enum Source: Hashable, Sendable {
    /// A GitHub Actions job (its id is its check run's): the failed step's log comes from `gh run view`.
    case job(repository: String, run: Int, id: Int)
    /// Another app's check run on GitHub (CodeQL, …): its title and summary come from the API.
    case checkRun(repository: String, id: Int)
    /// A page off GitHub (another CI, a deploy): it opens in the browser.
    case elsewhere(URL)
    /// Nothing Glance can show.
    case unknown
  }

  public struct Check: Equatable, Sendable {
    public let name: String
    /// The Actions workflow ("Lint"); empty for other checks.
    public let workflow: String
    public let outcome: Outcome
    /// A commit status's description (gh gives check runs none).
    public let description: String
    public let startedAt: Date?
    public let completedAt: Date?
    public let source: Source

    public init(
      name: String, workflow: String = "", outcome: Outcome, description: String = "", startedAt: Date? = nil,
      completedAt: Date? = nil, source: Source = .unknown
    ) {
      self.name = name
      self.workflow = workflow
      self.outcome = outcome
      self.description = description
      self.startedAt = startedAt
      self.completedAt = completedAt
      self.source = source
    }

    /// One of the page's own checks (`statusCheckRollup`), until gh pr checks answers: its name and outcome.
    public init(_ check: PullRequestPage.Check) {
      self.init(name: check.name, outcome: check.outcome)
    }
  }

  /// The checks with one outcome, as the page lists them.
  public struct Group: Equatable, Sendable {
    public let outcome: Outcome
    public let checks: [Check]
  }

  public static let fields = "name,state,bucket,link,workflow,description,startedAt,completedAt"

  public static func arguments(number: Int, repository: String) -> [String] {
    ["pr", "checks", String(number), "--repo", repository, "--json", fields]
  }

  /// `gh pr checks --json` output; nil when it isn't a list.
  public static func parse(_ data: Data) -> [Check]? {
    guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
    return items.compactMap { item in
      guard let name = item["name"] as? String else { return nil }
      return Check(
        name: name,
        workflow: item["workflow"] as? String ?? "",
        outcome: outcome(bucket: item["bucket"] as? String ?? ""),
        description: item["description"] as? String ?? "",
        startedAt: time(item["startedAt"]),
        completedAt: time(item["completedAt"]),
        source: source(link: item["link"] as? String ?? ""))
    }
  }

  /// gh pr checks fails on a branch with no checks at all ("no checks reported on the 'x' branch"): that's an empty
  /// list, not a failure.
  public static func isNoChecks(_ failure: PullRequests.Failure) -> Bool {
    guard case .failed(let line) = failure else { return false }
    return line.hasPrefix("no checks reported")
  }

  /// gh's bucket: pass, fail, cancel (failed, as GitHub's merge box counts it), pending, skipping. Anything newer
  /// counts as still running.
  public static func outcome(bucket: String) -> Outcome {
    switch bucket {
    case "pass": .passed
    case "fail", "cancel": .failed
    case "skipping": .skipped
    default: .running
    }
  }

  /// Where a check ran: an Actions job (".../o/r/actions/runs/RUN/job/ID"), a check run (".../o/r/runs/ID"), or a page
  /// off GitHub. Any other github.com page is `.unknown`: Glance doesn't open github.com.
  public static func source(link: String) -> Source {
    guard let url = URL(string: link), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
      let host = url.host?.lowercased() else { return .unknown }
    guard host == "github.com" || host == "www.github.com" else { return .elsewhere(url) }
    let parts = url.path.split(separator: "/").map(String.init)
    if parts.count >= 7, parts[2] == "actions", parts[3] == "runs", parts[5] == "job", let run = Int(parts[4]),
      let id = Int(parts[6]) {
      return .job(repository: parts[0] + "/" + parts[1], run: run, id: id)
    }
    if parts.count == 4, parts[2] == "runs", let id = Int(parts[3]) {
      return .checkRun(repository: parts[0] + "/" + parts[1], id: id)
    }
    return .unknown
  }

  /// The page's groups: failing, running, passing, then skipped, each in gh's order. Empty ones are left out.
  public static func groups(_ checks: [Check]) -> [Group] {
    [Outcome.failed, .running, .passed, .skipped].compactMap { outcome in
      let members = checks.filter { $0.outcome == outcome }
      return members.isEmpty ? nil : Group(outcome: outcome, checks: members)
    }
  }

  /// Every check in the page's order.
  public static func ordered(_ checks: [Check]) -> [Check] {
    groups(checks).flatMap(\.checks)
  }

  /// How long a check ran ("45s", "1m 33s", "2h 5m"), or has been running at `now`. Nil when it hasn't started, was
  /// skipped, or GitHub's times run backwards.
  public static func duration(_ check: Check, now: Date) -> String? {
    let end = check.outcome == .running ? now : check.completedAt
    guard check.outcome != .skipped, let start = check.startedAt, let end else { return nil }
    let seconds = Int(end.timeIntervalSince(start).rounded(.down))
    guard seconds >= 0 else { return nil }
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
    return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
  }

  /// gh's times. Go's zero time ("0001-01-01T00:00:00Z", a time gh doesn't have) is nil.
  static func time(_ value: Any?) -> Date? {
    guard let text = value as? String, let date = try? Date(text, strategy: .iso8601),
      date.timeIntervalSince1970 > 0 else { return nil }
    return date
  }

  // MARK: A failed job's log, a check run's summary, Re-run

  /// The end of a failed step's log.
  public struct Log: Equatable, Sendable {
    /// The step: gh's name for it, else the "Run …" header above the error. Empty when neither is known.
    public let step: String
    public let lines: [Line]
    /// The step's lines before these.
    public let omitted: Int
  }

  public struct Line: Equatable, Sendable {
    public let text: String
    /// An `##[error]` line.
    public let isError: Bool
  }

  /// Another app's check run: its output's title and summary (Markdown).
  public struct Output: Equatable, Sendable {
    public let title: String
    public let summary: String

    public init(title: String, summary: String) {
      self.title = title
      self.summary = summary
    }
  }

  /// gh's step name when it can't split a job's log into steps (it prints the whole job then).
  private static let unknownStep = "UNKNOWN STEP"

  private struct LogEntry {
    let step: String
    let line: Line
    /// "x" for a "##[group]Run x" line: a step's first line.
    let header: String?
  }

  public static func logArguments(repository: String, run: Int, job: Int) -> [String] {
    ["run", "view", String(run), "--repo", repository, "--log-failed", "--job", String(job)]
  }

  /// Re-runs a workflow run's failed jobs (and the jobs that need them).
  public static func rerunArguments(repository: String, run: Int) -> [String] {
    ["run", "rerun", String(run), "--repo", repository, "--failed"]
  }

  public static func checkRunArguments(repository: String, id: Int) -> [String] {
    ["api", "repos/\(repository)/check-runs/\(id)"]
  }

  /// The end of a failed job's log, from `gh run view --log-failed --job` (lines of "job⇥step⇥time text"): the last
  /// step gh printed, up to its last `##[error]` line, at most `keep` lines of it. Timestamps, colours and group markers
  /// are taken out. When gh can't tell the steps apart ("UNKNOWN STEP": the whole job, cleanup and all), the cut at the
  /// error keeps the cleanup out, and the "Run …" header above it names the step. Nil when there's no log.
  public static func log(_ output: String, keep: Int = 40) -> Log? {
    var entries: [LogEntry] = []
    for row in output.split(whereSeparator: \.isNewline) {
      let columns = row.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
      guard columns.count == 3 else { continue }
      var text = String(columns[2]).replacingOccurrences(of: "\u{FEFF}", with: "")
      text = text.replacingOccurrences(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z ?"#, with: "",
                                       options: .regularExpression)
      text = text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
      var isError = false
      var header: String?
      if text.hasPrefix("##["), let close = text.firstIndex(of: "]") {
        let marker = String(text[text.index(text.startIndex, offsetBy: 3)..<close])
        text = String(text[text.index(after: close)...])
        switch marker {
        case "endgroup": continue
        case "error": isError = true
        case "group" where text.hasPrefix("Run "): header = String(text.dropFirst(4))
        default: break
        }
      }
      entries.append(LogEntry(step: String(columns[1]), line: Line(text: text, isError: isError), header: header))
    }
    guard let last = entries.last else { return nil }
    var block = entries[...]
    if last.step != unknownStep, let other = entries.lastIndex(where: { $0.step != last.step }) {
      block = entries[(other + 1)...]
    }
    if let error = block.lastIndex(where: { $0.line.isError }) { block = block[...error] }
    let step = last.step != unknownStep ? last.step : block.last(where: { $0.header != nil })?.header ?? ""
    let kept = block.suffix(keep)
    return Log(step: step, lines: kept.map { $0.line }, omitted: block.count - kept.count)
  }

  /// `gh api repos/o/r/check-runs/ID`: its output's title and summary. Nil when it isn't a check run.
  public static func parseOutput(_ data: Data) -> Output? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["id"] != nil else {
      return nil
    }
    let output = object["output"] as? [String: Any]
    return Output(title: output?["title"] as? String ?? "", summary: output?["summary"] as? String ?? "")
  }
}
