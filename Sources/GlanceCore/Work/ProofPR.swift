import Foundation

/// The PR side of proof (spec §3): the PR for a session's branch, its preview URL, publishing the summary, merging.
/// Everything goes through `gh`; nothing opens github.com. Blocking: call off the main thread.
public enum ProofPR {
  public struct Info: Equatable, Sendable {
    public var number: Int
    public var url: String
    /// OPEN, CLOSED or MERGED.
    public var state: String
    public var merged: Bool
    public var checksFailing: Bool
    /// All the checks in one word: failing outweighs pending, no checks at all is `.empty`.
    public var checks: PullRequests.Checks.State
    /// The PR's branch.
    public var head: String
    /// "owner/name" of the repository the PR is in (the base, from the PR's address), "" when the address isn't one.
    public var repository: String
    /// The branch the PR merges into ("" when gh didn't say).
    public var base: String
    /// When the PR last changed (a new comment counts), as GitHub wrote it; "" when gh didn't say.
    public var updatedAt: String

    public init(number: Int, url: String, state: String, merged: Bool, checksFailing: Bool, head: String,
                repository: String, base: String = "", updatedAt: String = "", checks: PullRequests.Checks.State = .empty) {
      self.number = number; self.url = url; self.state = state; self.merged = merged
      self.checksFailing = checksFailing; self.checks = checks; self.head = head; self.repository = repository
      self.base = base; self.updatedAt = updatedAt
    }
  }

  /// Why a step failed, in words for the user. (`String` itself isn't an `Error`.)
  public struct Failure: Error, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
  }

  /// The fields `find` asks `gh pr view` for.
  static let fields = "number,url,state,headRefName,baseRefName,statusCheckRollup,updatedAt"

  // MARK: - Lookup

  /// The PR of `branch`, nil when there is none or gh can't say (not installed, signed out, no GitHub remote): see
  /// `lookup` for the reason.
  public static func find(branch: String, folder: String) -> Info? {
    if case .success(let info) = lookup(branch: branch, folder: folder) { return info }
    return nil
  }

  /// The PR of `branch`: `.success(nil)` when it has none yet, `.failure` with gh's reason when gh can't answer.
  /// `timeout` ends a gh that does not answer, as a failure.
  public static func lookup(branch: String, folder: String, timeout: TimeInterval? = nil) -> Result<Info?, Failure> {
    guard !branch.isEmpty, !branch.hasPrefix("-") else { return .success(nil) }
    switch GitHubCLI.run(PullRequests.executable(), ["pr", "view", branch, "--json", fields], folder: folder, timeout: timeout) {
    case .success(let data): return .success(parse(data))
    case .failure(.failed(let line)) where line.contains("no pull requests found"): return .success(nil)
    case .failure(let failure): return .failure(Failure(failure.message))
    }
  }

  /// The PR in `gh pr view --json …`. Nil when it isn't an object with a number.
  public static func parse(_ data: Data) -> Info? {
    guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let number = (o["number"] as? NSNumber)?.intValue else { return nil }
    let url = o["url"] as? String ?? ""
    let state = (o["state"] as? String ?? "").uppercased()
    let rollup = o["statusCheckRollup"] as? [[String: Any]] ?? []
    let rollupChecks = PullRequests.Checks(rollup: rollup)
    return Info(number: number, url: url, state: state, merged: state == "MERGED",
                checksFailing: rollupChecks.failed > 0,
                head: o["headRefName"] as? String ?? "", repository: repository(ofPullRequestURL: url),
                base: o["baseRefName"] as? String ?? "", updatedAt: o["updatedAt"] as? String ?? "",
                checks: rollupChecks.state)
  }

  /// "owner/name" from `https://github.com/owner/name/pull/12` (the repository the PR is in, not a fork's head), with
  /// the host in front on a GitHub Enterprise server; "" for anything else.
  static func repository(ofPullRequestURL address: String) -> String {
    guard let url = URL(string: address), let host = url.host else { return "" }
    let parts = url.pathComponents.filter { $0 != "/" }
    guard parts.count >= 4, parts[2] == "pull" else { return "" }
    let name = parts[0] + "/" + parts[1]
    return host == "github.com" ? name : host + "/" + name
  }

  // MARK: - Text for media

  /// At most this many comments are read for media, and this much of each text.
  static let maxCommentsRead = 100
  static let maxTextRead = 100_000

  /// The PR's description and comments as they are right now, for the images and videos in them, and when the PR last
  /// changed. Blocking.
  public static func bodies(info: Info, folder: String?) -> Result<(texts: [String], updatedAt: String), Failure> {
    switch gh(["pr", "view", String(info.number), "--json", "body,comments,updatedAt"] + repoArguments(info), folder: folder) {
    case .failure(let failure): return .failure(failure)
    case .success(let data): return parseBodies(data)
    }
  }

  /// The texts in `gh pr view --json body,comments,updatedAt`: the description, then each comment, empty ones left out
  /// and long ones cut (the text is anyone's). `null` for a description is an empty one.
  static func parseBodies(_ data: Data) -> Result<(texts: [String], updatedAt: String), Failure> {
    guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return .failure(Failure("GitHub sent something Glance can't read."))
    }
    var texts: [String] = []
    if let body = o["body"] as? String, !body.isEmpty { texts.append(String(body.prefix(maxTextRead))) }
    for comment in (o["comments"] as? [[String: Any]] ?? []).prefix(maxCommentsRead) {
      if let body = comment["body"] as? String, !body.isEmpty { texts.append(String(body.prefix(maxTextRead))) }
    }
    return .success((texts, o["updatedAt"] as? String ?? ""))
  }

  // MARK: - Preview URL

  /// The environment's URL: its fixed `url`, else its `urlScript`, else (`gh-deployments`) the PR's latest GitHub
  /// deployment that has one. `root` is the folder the setup was found in (the script's working directory, which for a
  /// linked worktree can be the main checkout); `worktree` is the session's own and goes to the script as
  /// `GLANCE_WORKTREE`.
  public static func previewURL(env: ProofSetup.Environment, info: Info?, root: String, branch: String?,
                                worktree: String?) -> Result<String, Failure> {
    if let url = env.url, !url.isEmpty { return .success(url) }
    guard let script = env.urlScript, !script.isEmpty else { return .failure(Failure("No url or urlScript.")) }
    if script == "gh-deployments" { return latestDeploymentURL(info: info, root: root, branch: branch) }
    var vars: [String: String] = [:]
    if let branch { vars["GLANCE_BRANCH"] = branch }
    if let info { vars["GLANCE_PR"] = String(info.number) }
    if let worktree { vars["GLANCE_WORKTREE"] = worktree }
    switch ProofScript.run(script, root: root, environment: vars) {
    case .output(let text):
      guard let url = ProofScript.lastURL(in: text) else {
        return .failure(Failure(text.isEmpty ? "\(script) printed nothing." : "\(script) printed no URL:\n" + String(text.suffix(500))))
      }
      return .success(url)
    case .failed(let message): return .failure(Failure(message))
    }
  }

  /// The newest deployment of the branch that has a successful status with an environment URL (Vercel, Netlify and
  /// the like report their preview there).
  private static func latestDeploymentURL(info: Info?, root: String, branch: String?) -> Result<String, Failure> {
    let branch = branch ?? info?.head
    guard let branch, !branch.isEmpty else { return .failure(Failure("No branch to look up deployments for.")) }
    let repo = info.map(\.repository).flatMap { $0.isEmpty ? nil : $0 } ?? "{owner}/{repo}"
    let listed = gh(["api", "--method", "GET", "repos/\(repo)/deployments", "-f", "ref=\(branch)", "-f", "per_page=5"],
                    folder: root)
    switch listed {
    case .failure(let failure): return .failure(failure)
    case .success(let data):
      for id in deploymentIDs(data) {
        if case .success(let statuses) = gh(["api", "repos/\(repo)/deployments/\(id)/statuses"], folder: root),
           let url = deploymentURL(inStatuses: statuses) { return .success(url) }
      }
      return .failure(Failure("No deployment with a URL for \(branch) yet."))
    }
  }

  /// The ids in `gh api repos/…/deployments` (newest first).
  static func deploymentIDs(_ data: Data) -> [Int] {
    guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    return list.compactMap { ($0["id"] as? NSNumber)?.intValue }
  }

  /// The environment URL of the newest successful status in `gh api repos/…/deployments/<id>/statuses`.
  static func deploymentURL(inStatuses data: Data) -> String? {
    guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
    return list.first { ($0["state"] as? String) == "success" && !(($0["environment_url"] as? String) ?? "").isEmpty }?[
      "environment_url"] as? String
  }

  // MARK: - Publish and merge

  /// Writes `summary` into the PR description between the proof markers. The description is read again right now, so
  /// whatever was edited since stays.
  public static func publish(summary: String, info: Info, folder: String) -> Result<Void, Failure> {
    let body: String
    switch description(with: summary, info: info, folder: folder) {
    case .failure(let failure): return .failure(failure)
    case .success(let updated): body = updated
    }
    return gh(editArguments(info), input: Data(body.utf8), folder: folder).map { _ in () }
  }

  /// The PR's description as it is right now, with `summary` in place of its proof block (or appended). Read from GitHub
  /// each time, so whatever was edited since stays; a reply with no `body` fails (see `updatedBody`). Blocking.
  public static func description(with summary: String, info: Info, folder: String?) -> Result<String, Failure> {
    let data: Data
    switch gh(["pr", "view", String(info.number), "--json", "body"] + repoArguments(info), folder: folder) {
    case .failure(let failure): return .failure(Failure("Couldn't read #\(info.number)'s description: \(failure.message)"))
    case .success(let read): data = read
    }
    switch updatedBody(from: data, summary: summary) {
    case .failure(let failure): return .failure(Failure("#\(info.number): \(failure.message)"))
    case .success(let body): return .success(body)
    }
  }

  private static func editArguments(_ info: Info) -> [String] {
    info.repository.isEmpty ? ["pr", "edit", String(info.number), "--body-file", "-"]
      : PullRequestActions.editBody(info.number, repository: info.repository)
  }

  /// `gh pr view --json body`'s description with `summary` in place. A reply without a `body` text fails: the
  /// description is never rewritten from an empty guess (`null` is an empty description, as GitHub can send it).
  public static func updatedBody(from data: Data, summary: String) -> Result<String, Failure> {
    guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let value = o["body"] else {
      return .failure(Failure("GitHub sent no description to build on."))
    }
    if value is NSNull { return .success(ProofSummary.replacing(in: "", with: summary)) }
    guard let current = value as? String else { return .failure(Failure("GitHub sent a description Glance can't read.")) }
    return .success(ProofSummary.replacing(in: current, with: summary))
  }

  /// Merges the PR with a merge commit. Only called when the user chose to; refuses a PR that isn't open.
  public static func merge(info: Info, folder: String) -> Result<Void, Failure> {
    guard info.state == "OPEN" else { return .failure(Failure("#\(info.number) is \(info.state.lowercased()), not open.")) }
    let arguments = info.repository.isEmpty ? ["pr", "merge", String(info.number), "--merge"]
      : PullRequestActions.merge(info.number, repository: info.repository, method: .merge)
    return gh(arguments, folder: folder).map { _ in () }
  }

  // MARK: - gh

  private static func repoArguments(_ info: Info) -> [String] {
    info.repository.isEmpty ? [] : ["--repo", info.repository]
  }

  private static func gh(_ arguments: [String], input: Data? = nil, folder: String?) -> Result<Data, Failure> {
    switch GitHubCLI.run(PullRequests.executable(), arguments, input: input, folder: folder) {
    case .success(let data): .success(data)
    case .failure(let failure): .failure(Failure(failure.message))
    }
  }
}
