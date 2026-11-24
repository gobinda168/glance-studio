import Foundation

/// Where a tab is, for the top bar: the worktree or checkout it's in and its branch. Read from the `.git` files (no git
/// process), so it can refresh every few seconds.
public enum TabLocation {
  public enum Head: Equatable, Sendable {
    case branch(String)
    case detached(String)

    public var label: String {
      switch self {
      case let .branch(name): name
      case let .detached(commit): "detached \(commit)"
      }
    }
  }

  public struct Location: Equatable, Sendable {
    /// The worktree's or checkout's own folder name.
    public let folder: String
    /// Its top folder, with `~` for the home folder.
    public let path: String
    /// The main checkout's folder name when this is a linked worktree, else nil.
    public let repository: String?
    public let head: Head

    public init(folder: String, path: String, repository: String?, head: Head) {
      self.folder = folder
      self.path = path
      self.repository = repository
      self.head = head
    }

    public var isLinkedWorktree: Bool { repository != nil }

    /// "Worktree of acme at ~/wt/rotate, on priya/x, against main", for the tooltip and VoiceOver.
    public func sentence(base: String?) -> String {
      let place = repository.map { "Worktree of \($0) at \(path)" } ?? "Main checkout at \(path)"
      switch head {
      case let .detached(commit):
        return "\(place), detached at \(commit)"
      case let .branch(name):
        guard let base else { return "\(place), on \(name)" }
        return "\(place), on \(name)" + (name == base ? ", the base branch" : ", against \(base)")
      }
    }
  }

  /// Nil outside a repo or when HEAD can't be read.
  public static func read(folder: String, home: String = NSHomeDirectory()) -> Location? {
    let root = ProjectRoot.find(from: folder, home: home)
    guard let name = GitHead.branch(inFolder: folder, home: home) else { return nil }
    return Location(folder: FolderLabel.name(forPath: root, home: home), path: shortened(root, home: home),
                    repository: repository(ofLinkedWorktree: root),
                    head: GitHead.looksDetached(name) ? .detached(name) : .branch(name))
  }

  /// The main checkout's folder name when `root` is a linked worktree: its `.git` is a file pointing into the main
  /// repository's `.git/worktrees/`. A submodule's `.git` file points into `.git/modules/` instead.
  public static func repository(ofLinkedWorktree root: String) -> String? {
    let dotGit = root + "/.git"
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory), !isDirectory.boolValue,
          let pointer = try? String(contentsOfFile: dotGit, encoding: .utf8),
          let line = pointer.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return nil }
    let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
    let worktrees = URL(fileURLWithPath: target.hasPrefix("/") ? target : root + "/" + target).standardizedFileURL
      .deletingLastPathComponent()
    guard worktrees.lastPathComponent == "worktrees" else { return nil }
    return worktrees.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
  }

  private static func shortened(_ path: String, home: String) -> String {
    let home = SessionMatch.normalize(home, home: home)
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
  }
}
