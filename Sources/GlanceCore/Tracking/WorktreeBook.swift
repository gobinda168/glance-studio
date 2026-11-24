import Foundation

/// One worktree of a repository with what the tracking hooks know about it.
public struct WorktreeInfo: Equatable, Sendable {
  public var path: String
  public var branch: String?
  public var isMain: Bool
  public var files: [AttributedFile]
  public var sessions: [TrackedSession]
  /// The ids of `sessions` that are live.
  public var live: Set<String>
  public var merged: Bool
  public var tooMany: Bool
  public var warning: Bool
  /// Lines added and removed against HEAD (`git diff HEAD --numstat`; untracked files aren't counted).
  public var added: Int
  public var removed: Int
  public var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

/// A repository with tracking state and all of its worktrees, the main one first.
public struct RepoTree: Equatable, Sendable {
  /// The common git folder.
  public var repo: String
  public var name: String
  public var main: String
  public var worktrees: [WorktreeInfo]
  /// Sessions whose worktree git no longer lists (removed, branch deleted): they stay on the board.
  public var orphans: [TrackedSession] = []
}

/// What the Worktrees view draws (spec §3): every repository with tracking state, all of its worktrees from git,
/// each with its uncommitted files by author and its sessions.
public enum WorktreeBook {
  public struct Listed: Equatable, Sendable {
    public var path: String
    public var branch: String?
    public var isMain: Bool
  }

  /// `git worktree list --porcelain`: the first block is the main worktree.
  public static func parseList(_ output: String) -> [Listed] {
    var listed: [Listed] = []
    var path: String?
    var branch: String?
    func flush() {
      if let path { listed.append(Listed(path: path, branch: branch, isMain: listed.isEmpty)) }
      path = nil
      branch = nil
    }
    for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.hasPrefix("worktree ") {
        flush()
        path = String(line.dropFirst("worktree ".count))
      } else if line.hasPrefix("branch refs/heads/") {
        branch = String(line.dropFirst("branch refs/heads/".count))
      } else if line.isEmpty {
        flush()
      }
    }
    flush()
    return listed
  }

  /// A worktree mixes work: files by more than one author, or more than one live session.
  public static func warning(files: [AttributedFile], live: Int) -> Bool {
    Set(files.map(\.author)).count > 1 || live > 1
  }

  /// Total lines added and removed in `git diff --numstat` output (binary files, "-", count as 0).
  public static func numstat(_ output: String) -> (Int, Int) {
    output.split(separator: "\n").reduce((0, 0)) { total, line in
      let fields = line.split(separator: "\t")
      guard fields.count >= 2 else { return total }
      return (total.0 + (Int(fields[0]) ?? 0), total.1 + (Int(fields[1]) ?? 0))
    }
  }

  /// Whether a worktree may be offered for removal: not the main one, its status was read in full, nothing is
  /// uncommitted and no session is live in it, and its branch is merged. `merged` runs last, as it spawns git.
  public static func removable(isMain: Bool, statusRead: Bool, tooMany: Bool, files: Int, live: Int,
                               merged: () -> Bool) -> Bool {
    !isMain && statusRead && !tooMany && files == 0 && live == 0 && merged()
  }

  /// Every repository the ledger knows, with its worktrees read from git now. A repository git can't list (moved or
  /// deleted) is left out. git is pointed at the common git folder itself (`--git-dir`), so a submodule or a
  /// repository whose git folder isn't `<main>/.git` lists its own worktrees.
  public static func load(ledger: Ledger = Ledger(), alive: (Int32) -> Bool = ProcessTree.isClaude) -> [RepoTree] {
    ledger.repos().compactMap { repo in
      let state = ledger.state(repo: repo)
      let anywhere = URL(fileURLWithPath: repo).deletingLastPathComponent().path
      guard let list = GitRun.text(anywhere, ["--git-dir=" + repo, "worktree", "list", "--porcelain"]) else {
        return nil
      }
      let listed = parseList(list)
      guard let main = listed.first?.path else { return nil }
      let worktrees = listed.map { item -> WorktreeInfo in
        let read = Fingerprint.current(root: item.path, previous: state.fingerprints[item.path])
        let fingerprint = read ?? Fingerprint()
        let files = Uncommitted.attribute(fingerprint, authors: state.authors[item.path] ?? [:])
        let sessions = state.sessions.values.filter { $0.worktree == item.path }.sorted { $0.started > $1.started }
        let live = Set(sessions.filter { $0.isLive(alive) }.map(\.id))
        let merged = removable(isMain: item.isMain, statusRead: read != nil, tooMany: fingerprint.tooMany,
                               files: files.count, live: live.count) {
          item.branch.map { WorktreeActions.isMerged(branch: $0, mainRoot: main) } ?? false
        }
        let lines = files.isEmpty ? (0, 0) : numstat(GitRun.text(item.path, ["diff", "HEAD", "--numstat"]) ?? "")
        return WorktreeInfo(path: item.path, branch: item.branch, isMain: item.isMain, files: files,
                            sessions: sessions, live: live, merged: merged, tooMany: fingerprint.tooMany,
                            warning: warning(files: files, live: live.count), added: lines.0, removed: lines.1)
      }
      let listedPaths = Set(listed.map(\.path))
      let orphans = state.sessions.values.filter { !listedPaths.contains($0.worktree) }.sorted { $0.started > $1.started }
      return RepoTree(repo: repo, name: URL(fileURLWithPath: main).lastPathComponent, main: main, worktrees: worktrees, orphans: orphans)
    }
  }
}
