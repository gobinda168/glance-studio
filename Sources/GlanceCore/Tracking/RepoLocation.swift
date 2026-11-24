import Foundation

/// Where a folder sits in git: its worktree's top folder, the repository's common git folder (the same for every
/// worktree of one repository, so it is the repository's key) and the branch, nil when detached.
public struct RepoLocation: Equatable, Sendable {
  public var worktree: String
  public var commonDir: String
  public var branch: String?

  public init(worktree: String, commonDir: String, branch: String?) {
    self.worktree = worktree
    self.commonDir = commonDir
    self.branch = branch
  }

  /// Parses `git rev-parse --path-format=absolute --show-toplevel --git-common-dir --abbrev-ref HEAD` run in `cwd`.
  /// Nil when git printed nothing (not a repository, or a repository with no commit yet).
  public static func parse(_ output: String, cwd: String) -> RepoLocation? {
    let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard lines.count >= 3, !lines[0].isEmpty, !lines[1].isEmpty else { return nil }
    let common = lines[1].hasPrefix("/") ? lines[1] : cwd + "/" + lines[1]
    let branch = lines[2] == "HEAD" || lines[2].isEmpty ? nil : lines[2]
    return RepoLocation(worktree: lines[0], commonDir: URL(fileURLWithPath: common).standardizedFileURL.path,
                        branch: branch)
  }

  public static func find(cwd: String) -> RepoLocation? {
    GitRun.text(cwd, ["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir",
                      "--abbrev-ref", "HEAD"])
      .flatMap { parse($0, cwd: cwd) }
  }
}
