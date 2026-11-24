import Foundation

/// The fixes and actions Glance and Claude offer (spec §2–3). Each runs git and returns git's message on failure;
/// none deletes uncommitted work (`git worktree remove` refuses a dirty tree, `git branch -d` an unmerged branch).
public enum WorktreeActions {
  public struct Failure: Error, Equatable {
    public var message: String
  }

  /// A task name as a folder and branch name: lowercase letters, digits and dashes, at most 40 characters.
  public static func slug(_ task: String) -> String {
    let lowered = task.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
    let collapsed = String(lowered).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
    let short = String(collapsed.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return short.isEmpty ? "task" : short
  }

  /// `origin/<default>` when the remote's HEAD is known, else the current branch.
  public static func defaultBase(repoRoot: String) -> String {
    if let remote = GitRun.text(repoRoot, ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"])?
      .trimmingCharacters(in: .whitespacesAndNewlines), !remote.isEmpty {
      return remote
    }
    return GitRun.text(repoRoot, ["rev-parse", "--abbrev-ref", "HEAD"])?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? "HEAD"
  }

  /// A new worktree `../<repo>-<slug>` on a new branch `<slug>` from `base` (default: `defaultBase`), numbered when
  /// the name is taken.
  public static func create(repoRoot: String, task: String, from base: String?) -> Result<(path: String, branch: String), Failure> {
    let root = URL(fileURLWithPath: repoRoot)
    let name = slug(task)
    var branch = name
    var path = root.deletingLastPathComponent().appendingPathComponent("\(root.lastPathComponent)-\(name)").path
    var number = 2
    while FileManager.default.fileExists(atPath: path)
      || GitRun.data(repoRoot, ["rev-parse", "--verify", "--quiet", "refs/heads/" + branch]) != nil {
      branch = "\(name)-\(number)"
      path = root.deletingLastPathComponent().appendingPathComponent("\(root.lastPathComponent)-\(branch)").path
      number += 1
    }
    // --no-track: the new branch is the task's own, not a branch that pulls from origin/main.
    let start = base ?? defaultBase(repoRoot: repoRoot)
    guard GitRun.data(repoRoot, ["worktree", "add", "-q", "--no-track", "-b", branch, path, start]) != nil else {
      return .failure(Failure(message: "git couldn't create the worktree \(path)"))
    }
    return .success((path, branch))
  }

  /// Commits exactly `files` (paths relative to the worktree), new ones included, leaving everything else as it is.
  public static func commit(worktree: String, files: [String], message: String) -> Failure? {
    guard !files.isEmpty else { return Failure(message: "No files to commit.") }
    guard GitRun.data(worktree, ["add", "--"] + files) != nil else { return Failure(message: "git add failed.") }
    guard GitRun.data(worktree, ["commit", "-q", "-m", message, "--"] + files) != nil else {
      return Failure(message: "git commit failed.")
    }
    return nil
  }

  /// Moves `files`' uncommitted changes to a new worktree from the current HEAD, then restores them here. The
  /// changes are read before anything is created and copied before anything is restored: when reading or copying
  /// fails the new worktree and branch are removed again and this worktree is left as it was.
  public static func move(files: [AttributedFile], from worktree: String, task: String) -> Result<(path: String, branch: String), Failure> {
    let tracked = files.filter { $0.status != "??" }
    let added = tracked.filter { $0.status.first == "A" }.map(\.path)
    let others = tracked.filter { $0.status.first != "A" }.map(\.path)
    let untracked = files.filter { $0.status == "??" }.map(\.path)
    var patch = Data()
    if !tracked.isEmpty {
      guard let read = GitRun.data(worktree, ["diff", "HEAD", "--binary", "--no-color", "--no-ext-diff", "--"] + tracked.map(\.path)) else {
        return .failure(Failure(message: "git couldn't read the changes; nothing was moved."))
      }
      patch = read
    }
    guard case .success(let made) = create(repoRoot: worktree, task: task, from: "HEAD") else {
      return .failure(Failure(message: "git couldn't create the new worktree."))
    }
    func abandon(_ message: String) -> Result<(path: String, branch: String), Failure> {
      _ = GitRun.data(worktree, ["worktree", "remove", "--force", made.path])
      _ = GitRun.data(worktree, ["branch", "-D", made.branch])
      return .failure(Failure(message: message))
    }
    if !patch.isEmpty {
      let file = FileManager.default.temporaryDirectory.appendingPathComponent("glance-move-\(UUID().uuidString).patch")
      defer { try? FileManager.default.removeItem(at: file) }
      guard (try? patch.write(to: file)) != nil, GitRun.data(made.path, ["apply", "--binary", file.path]) != nil else {
        return abandon("The changes couldn't be applied in the new worktree; nothing was moved.")
      }
    }
    for path in untracked {
      let target = URL(fileURLWithPath: made.path + "/" + path)
      try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      guard (try? FileManager.default.copyItem(atPath: worktree + "/" + path, toPath: target.path)) != nil else {
        return abandon("\(path) couldn't be copied; nothing was moved.")
      }
    }
    // Restore this worktree. Files new to git have no HEAD version to check out: unstage and delete them.
    var restored = true
    if !added.isEmpty {
      restored = GitRun.data(worktree, ["rm", "--cached", "-q", "-f", "--"] + added) != nil && restored
      for path in added { try? FileManager.default.removeItem(atPath: worktree + "/" + path) }
    }
    if !others.isEmpty { restored = GitRun.data(worktree, ["checkout", "HEAD", "--"] + others) != nil && restored }
    for path in untracked {
      do { try FileManager.default.removeItem(atPath: worktree + "/" + path) } catch { restored = false }
    }
    guard restored else {
      return .failure(Failure(message: "The changes were copied to \(made.path), but restoring them here failed, so both copies exist."))
    }
    return .success(made)
  }

  /// Whether `branch` is merged into the default base.
  public static func isMerged(branch: String, mainRoot: String) -> Bool {
    GitRun.data(mainRoot, ["merge-base", "--is-ancestor", branch, defaultBase(repoRoot: mainRoot)]) != nil
  }

  /// Removes a worktree (refused when it has uncommitted changes) and its branch (refused when unmerged).
  public static func remove(worktree: String, branch: String?, mainRoot: String) -> Failure? {
    guard GitRun.data(mainRoot, ["worktree", "remove", worktree]) != nil else {
      return Failure(message: "\(worktree) has uncommitted changes or couldn't be removed.")
    }
    if let branch, GitRun.data(mainRoot, ["branch", "-d", branch]) == nil {
      return Failure(message: "The worktree is gone; the branch \(branch) isn't merged, so it was kept.")
    }
    return nil
  }

  /// `git worktree add <path> <branch>`: a removed worktree back on its branch (spec §5). A failure says why, in words.
  /// Blocking git: never on the main thread.
  public static func recreate(path: String, branch: String, mainRoot: String) -> Failure? {
    guard path.hasPrefix("/") else { return Failure(message: "That path can't be used: it must be a full path, not \(path).") }
    // check-ref-format also rejects revision syntax (`x^`, `x~1`, `x@{1}`, `..`); `--branch` expands `@{-1}`, which isn't a name.
    guard !branch.isEmpty, !branch.hasPrefix("-"),
          GitRun.text(mainRoot, ["check-ref-format", "--branch", branch])?.trimmingCharacters(in: .whitespacesAndNewlines) == branch else {
      return Failure(message: "\(branch.isEmpty ? "That" : branch) isn't a branch name git can use.")
    }
    guard !FileManager.default.fileExists(atPath: path) else { return Failure(message: "Something is already at \(path).") }
    guard GitRun.data(mainRoot, ["show-ref", "--verify", "--quiet", "refs/heads/" + branch]) != nil else {
      return Failure(message: "The branch \(branch) no longer exists.")
    }
    if let there = checkedOut(branch: branch, mainRoot: mainRoot) {
      return Failure(message: "The branch \(branch) is already checked out at \(there).")
    }
    guard GitRun.data(mainRoot, ["worktree", "add", "-q", path, branch]) != nil else {
      return Failure(message: "git couldn't recreate the worktree \(path).")
    }
    return nil
  }

  /// Where `branch` is checked out, if in any worktree of the repository: git won't check one branch out twice.
  static func checkedOut(branch: String, mainRoot: String) -> String? {
    guard let list = GitRun.text(mainRoot, ["worktree", "list", "--porcelain"]) else { return nil }
    var folder: String?
    for line in list.split(separator: "\n") {
      if line.hasPrefix("worktree ") { folder = String(line.dropFirst("worktree ".count)) }
      if line == "branch refs/heads/\(branch)" { return folder }
    }
    return nil
  }
}
