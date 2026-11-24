import Foundation

/// A folder's branch against the base a pull request would merge into: what the top bar's Create PR needs. Local git
/// only, so it can refresh every few seconds.
public enum BranchSummary {
  public struct Summary: Equatable, Sendable {
    public let branch: String
    public let base: String
    public let additions: Int
    public let deletions: Int

    public init(branch: String, base: String, additions: Int, deletions: Int) {
      self.branch = branch
      self.base = base
      self.additions = additions
      self.deletions = deletions
    }
  }

  /// The base, nil without one on origin, and the summary, nil with nothing to raise.
  public struct Reading: Equatable, Sendable {
    public let base: String?
    public let summary: Summary?

    public init(base: String?, summary: Summary?) {
      self.base = base
      self.summary = summary
    }
  }

  /// `origin/main` when origin has a HEAD; the fallbacks are tried in order.
  public static let originHeadArguments = ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]
  public static let fallbackBases = ["origin/main", "origin/master"]

  /// The base's name without "origin/", from `symbolic-ref --short` output.
  public static func base(fromOriginHead output: String) -> String? {
    let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.hasPrefix("origin/"), text.count > "origin/".count else { return nil }
    return String(text.dropFirst("origin/".count))
  }

  /// The numstat of `origin/base...HEAD`. Nil when the branch is the base itself or has nothing against it, so Create
  /// PR stays hidden.
  public static func summary(branch: String, base: String, numstat: String) -> Summary? {
    guard branch != base else { return nil }
    let stats = BranchCompare.fileStats(numstat)
    guard !stats.isEmpty else { return nil }
    let totals = BranchCompare.totals(stats)
    return Summary(branch: branch, base: base, additions: totals.additions, deletions: totals.deletions)
  }

  /// Blocks: call it off the main thread. Nil outside a repo and on a detached HEAD.
  public static func read(folder: String) -> Reading? {
    func git(_ arguments: [String]) -> String? {
      guard let result = GitHubCLI.execute("/usr/bin/git", ["-C", folder] + arguments,
                                           environment: WorkingChanges.environment), result.status == 0 else { return nil }
      return String(decoding: result.output, as: UTF8.self)
    }
    guard let branch = GitHead.branch(inFolder: folder), !GitHead.looksDetached(branch) else { return nil }
    // Polled every few seconds: while HEAD and the base are the same commits the diff is too, so one rev-parse
    // answers instead of symbolic-ref and a diff.
    func fingerprint(_ base: String) -> String? {
      git(["rev-parse", "HEAD", BranchCompare.baseRef(base)])
    }
    if let last = cache.get(folder), last.branch == branch, let now = fingerprint(last.base), now == last.fingerprint {
      return Reading(base: last.base, summary: last.summary)
    }
    var candidates = [git(originHeadArguments).flatMap(base(fromOriginHead:))].compactMap { $0 }
    candidates += fallbackBases.compactMap { base(fromOriginHead: $0) }
    for base in candidates {
      let stamp = fingerprint(base)
      guard let numstat = git(BranchCompare.numstatArguments(base: base, head: "HEAD")) else { continue }
      let found = summary(branch: branch, base: base, numstat: numstat)
      if let stamp { cache.set(folder, Cached(branch: branch, base: base, fingerprint: stamp, summary: found)) }
      return Reading(base: base, summary: found)
    }
    return Reading(base: nil, summary: nil)
  }

  private struct Cached: Sendable {
    let branch: String
    let base: String
    let fingerprint: String
    let summary: Summary?
  }

  /// The last answer per folder (a handful: only the window in front is polled).
  private final class Cache: @unchecked Sendable {
    private let lock = NSLock()
    private var folders: [String: Cached] = [:]

    func get(_ folder: String) -> Cached? {
      lock.lock(); defer { lock.unlock() }
      return folders[folder]
    }

    func set(_ folder: String, _ value: Cached) {
      lock.lock(); defer { lock.unlock() }
      if folders.count > 16 { folders.removeAll() }
      folders[folder] = value
    }
  }

  private static let cache = Cache()
}
