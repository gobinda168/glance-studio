import Foundation

/// Which records are a pull request's proof (spec §3 "On the PR page"): those of its branch, in its repository.
public enum ProofRecords {
  /// Where a record's session ran, as far as the record can tell.
  public enum Home: Equatable, Sendable {
    /// The repository's git common directory (shared by all of its worktrees).
    case commonDir(String)
    /// Every folder the record names is gone (a worktree removed after its merge). Its repository can't be checked.
    case gone
    /// A folder that exists but git can't place in a repository, or a record that names no folder.
    case unknown
  }

  /// Branches every repository has: a record whose folders are gone and which has no stored repository can't be told
  /// from another repository's by one of these names.
  static let sharedBranches: Set<String> = ["main", "master", "develop", "trunk"]

  /// The records of `branch` that ran in the repository at `commonDir`, newest first (equal times by session id).
  /// The branch is compared first. A record that stored its repository (`commonDir`) is compared with it, no git; an
  /// older one is placed by `resolve` (git, per record, so only for the few that share the branch). An older record
  /// whose folders are all gone is kept by its branch name, unless that is one every repository has: a merged PR
  /// must still show its proof. Paths are compared with symlinks resolved and no trailing slash.
  public static func match(_ records: [WorkRecord], branch: String, commonDir: String,
                           resolve: (WorkRecord) -> Home) -> [WorkRecord] {
    guard !branch.isEmpty else { return [] }
    let wanted = GitCommonDir.normalize(commonDir)
    return records.filter { $0.branch == branch }
      .sorted { ($0.updated, $1.session) > ($1.updated, $0.session) }
      .filter { record in
        if let stored = record.commonDir, !stored.isEmpty { return GitCommonDir.normalize(stored) == wanted }
        switch resolve(record) {
        case .commonDir(let found): return GitCommonDir.normalize(found) == wanted
        case .gone: return !sharedBranches.contains(branch)
        case .unknown: return false
        }
      }
  }

  /// The folder to read a record's setup from: its worktree, else its cwd, whichever still exists.
  public static func folder(of record: WorkRecord) -> String? {
    [record.worktree, record.cwd].compactMap { $0 }.filter { !$0.isEmpty }
      .first { FileManager.default.fileExists(atPath: $0) }
  }

  /// Whether the record names a folder at all, and none of them exists any more.
  public static func isGone(_ record: WorkRecord) -> Bool {
    let named = [record.worktree, record.cwd].compactMap { $0 }.filter { !$0.isEmpty }
    return !named.isEmpty && folder(of: record) == nil
  }

  /// Where `record` ran. `commonDir` asks git about a folder (blocking: off the main thread).
  public static func home(of record: WorkRecord,
                          commonDir: (String) -> String? = { RepoLocation.find(cwd: $0)?.commonDir }) -> Home {
    if let folder = folder(of: record) { return commonDir(folder).map(Home.commonDir) ?? .unknown }
    return isGone(record) ? .gone : .unknown
  }

  /// Whether the git work tree at `folder` has changes not committed (untracked files count). Nil when git couldn't
  /// say (not a repository, an error, or no answer within `timeout` seconds, when git is terminated): callers treat
  /// that as "maybe", never as clean. Blocking.
  public static func hasUncommittedChanges(inFolder folder: String, timeout: TimeInterval = 5) -> Bool? {
    GitRun.text(folder, ["status", "--porcelain"], timeout: timeout).map { $0.contains { !$0.isWhitespace } }
  }
}
