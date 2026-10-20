import Foundation

/// Which past Claude Code sessions belong to a project, for the Terminal side bar's History: those started in the
/// project's root, in a folder inside it, or in a worktree of its repository. Claude Code keeps a session under its
/// working folder's spelled name (`ClaudeProjectFolder`), so a project's sessions are spread over several folders.
public enum HistoryProject {
  /// What a folder's `.git` is: the repository itself, or a worktree's pointer file ("gitdir: <repo>/.git/worktrees/x").
  public enum GitEntry: Equatable, Sendable {
    case repository
    case worktree(gitdir: String)
  }

  /// Whether a session started in `cwd` belongs to the project at `root`. A live folder outside the root belongs when
  /// its nearest `.git` points into the root's repository. A removed one (a merged worktree) belongs when it sat beside
  /// the root and its name starts with the root's and a dash ("app-fix-x" beside "app"), as worktrees are named here.
  public static func contains(
    cwd: String, root: String, home: String = NSHomeDirectory(),
    exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
    git: (String) -> GitEntry? = gitEntry
  ) -> Bool {
    let cwd = SessionMatch.normalize(cwd, home: home)
    let root = SessionMatch.normalize(root, home: home)
    if cwd == root || cwd.hasPrefix(root + "/") { return true }
    if exists(cwd) {
      let stop = SessionMatch.normalize(home, home: home)
      var current = cwd
      while current != "/" && current != stop {
        switch git(current) {
        case .repository: return false
        case .worktree(let gitdir): return SessionMatch.normalize(gitdir, home: home).hasPrefix(root + "/.git/worktrees/")
        case nil: current = (current as NSString).deletingLastPathComponent
        }
      }
      return false
    }
    let parent = (root as NSString).deletingLastPathComponent
    guard cwd.hasPrefix(parent + "/") else { return false }
    let sibling = cwd.dropFirst(parent.count + 1).split(separator: "/").first.map(String.init) ?? ""
    return sibling.hasPrefix((root as NSString).lastPathComponent + "-")
  }

  /// The transcript folders worth reading for `root`: its own and those whose spelled name starts with it (its
  /// subfolders, and siblings like its worktrees). A worktree elsewhere with another name is not looked for.
  public static func candidates(_ names: [String], root: String) -> [String] {
    let name = ClaudeProjectFolder.name(for: root)
    return names.filter { $0.hasPrefix(name) }
  }

  /// Where in the project a session ran, when not at its root: the subfolder ("terminal/macos") or the worktree's
  /// folder name.
  public static func place(cwd: String, root: String) -> String? {
    if cwd == root { return nil }
    if cwd.hasPrefix(root + "/") { return String(cwd.dropFirst(root.count + 1)) }
    let parent = (root as NSString).deletingLastPathComponent
    if cwd.hasPrefix(parent + "/") { return String(cwd.dropFirst(parent.count + 1)) }
    return (cwd as NSString).lastPathComponent
  }

  /// The working folder a transcript recorded: the first entry's `cwd` that has one.
  public static func cwd(jsonl: String) -> String? {
    for line in jsonl.split(separator: "\n") where line.contains("\"cwd\"") {
      guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
      if let cwd = object["cwd"] as? String, !cwd.isEmpty { return cwd }
    }
    return nil
  }

  /// `folder/.git` on disk: a directory is a repository, a file is a worktree's pointer.
  public static func gitEntry(_ folder: String) -> GitEntry? {
    let path = folder + "/.git"
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
    if isDirectory.boolValue { return .repository }
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
    var gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
    if !gitdir.hasPrefix("/") { gitdir = URL(fileURLWithPath: folder).appendingPathComponent(gitdir).standardizedFileURL.path }
    return .worktree(gitdir: gitdir)
  }
}
