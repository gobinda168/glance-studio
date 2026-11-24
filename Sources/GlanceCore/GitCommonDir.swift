import Foundation

/// The git common directory (shared by a repository's worktrees) read from files alone, no git: for hooks, which
/// must stay fast and must not start a process.
public enum GitCommonDir {
  /// For the folder `root` that holds `.git`: `.git` a folder is the common directory itself; `.git` a file says
  /// `gitdir: <path>` (a linked worktree or submodule), and that folder's `commondir` file points back at the common
  /// directory, relative to it. `linked` tells the two apart. Nil when something is unreadable.
  public static func of(root: URL) -> (commonDir: URL, linked: Bool)? {
    let dotGit = root.appendingPathComponent(".git")
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }
    if isDirectory.boolValue { return (dotGit.standardizedFileURL, false) }
    guard let pointer = try? String(contentsOf: dotGit, encoding: .utf8),
          let line = pointer.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
    let gitdirPath = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
    // The base must be a directory URL, or a relative gitdir resolves against the folder's parent.
    let gitdir = URL(fileURLWithPath: gitdirPath, relativeTo: URL(fileURLWithPath: root.path, isDirectory: true)).standardizedFileURL
    // A linked worktree's gitdir has a `commondir` file; a submodule's has none and is itself the common directory.
    guard let common = try? String(contentsOf: gitdir.appendingPathComponent("commondir"), encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines), !common.isEmpty else {
      return FileManager.default.fileExists(atPath: gitdir.path) ? (gitdir, true) : nil
    }
    return (URL(fileURLWithPath: common, relativeTo: gitdir).standardizedFileURL, true)
  }

  /// The common directory of the repository containing `folder`, as `normalize` writes it; nil outside a repository.
  public static func find(from folder: String, home: String = NSHomeDirectory()) -> String? {
    of(root: URL(fileURLWithPath: ProjectRoot.find(from: folder, home: home))).map { normalize($0.commonDir.path) }
  }

  /// A path to compare with another: symlinks resolved, no trailing slash.
  public static func normalize(_ path: String) -> String {
    var path = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path
  }
}
