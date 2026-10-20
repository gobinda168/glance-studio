import Foundation

/// Which folder on this Mac holds each GitHub repository (spec 2026-10-08-pr-repositories-design.md, "Folders on this
/// Mac"): "owner/name", lowercased, to a folder. A folder serves every GitHub repository among its remotes, so a fork's
/// clone serves the fork and the original (`gh repo clone` adds `upstream` for a fork). Clone… and Choose Folder…'s
/// rules live here too.
public struct RepositoryFolders: Equatable, Sendable {
  /// Lowercased "owner/name" → folder.
  public private(set) var folders: [String: String]

  public init(_ folders: [String: String] = [:]) {
    self.folders = Dictionary(folders.map { (Self.key($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
  }

  /// A repository's key here, and wherever repositories are compared: lowercased.
  public static func key(_ repository: String) -> String { repository.lowercased() }

  public func folder(for repository: String) -> String? { folders[Self.key(repository)] }

  /// Records `folder` for each of `repositories`. A found folder (`replacing` off) doesn't move one already recorded;
  /// Clone… and Choose Folder… (`replacing` on) do.
  public mutating func record(_ folder: String, for repositories: [String], replacing: Bool) {
    for repository in repositories {
      let key = Self.key(repository)
      if replacing || folders[key] == nil { folders[key] = folder }
    }
  }

  public mutating func remove(_ repository: String) {
    folders[Self.key(repository)] = nil
  }

  /// The launch check: a folder stays only for the repositories its remotes still list. `remotes` gives a folder's
  /// GitHub repositories, nil when it's gone or isn't a git repository; each folder is asked once.
  public func checked(remotes: (String) -> [String]?) -> RepositoryFolders {
    var asked: [String: Set<String>] = [:]
    var kept: [String: String] = [:]
    for (key, folder) in folders {
      if asked[folder] == nil { asked[folder] = Set((remotes(folder) ?? []).map(Self.key)) }
      if asked[folder]?.contains(key) == true { kept[key] = folder }
    }
    return RepositoryFolders(kept)
  }

  /// The folder a tab uses for `repository`: its own project (`own`, whose GitHub repositories are `ownRepositories`)
  /// when that is the repository, else the map's.
  public func folder(for repository: String, own: String?, ownRepositories: [String]) -> String? {
    if let own, ownRepositories.contains(where: { Self.key($0) == Self.key(repository) }) { return own }
    return folder(for: repository)
  }

  /// Choose Folder…'s verdict on a folder whose GitHub remotes are `remotes`.
  public enum Choice: Equatable, Sendable {
    case accepted
    /// The folder is another repository on GitHub (its first).
    case otherRepository(String)
    case notGitHub
  }

  public static func choice(for repository: String, remotes: [String]) -> Choice {
    if remotes.contains(where: { key($0) == key(repository) }) { return .accepted }
    if let first = remotes.first { return .otherRepository(first) }
    return .notGitHub
  }

  /// What the notice says about a folder Choose Folder… didn't take; nil when it took it.
  public static func message(_ choice: Choice) -> String? {
    switch choice {
    case .accepted: nil
    case .otherRepository(let other): "That folder is \(other) on GitHub."
    case .notGitHub: "That folder isn't a GitHub repository."
    }
  }

  /// Where Clone… puts `repository` inside `parent`: a folder with its name.
  public static func cloneDestination(_ repository: String, parent: String) -> String {
    let name = repository.split(separator: "/").last.map(String.init) ?? repository
    return (parent as NSString).appendingPathComponent(name)
  }

  /// `gh repo clone` of `repository` into `destination`. gh follows the user's git protocol.
  public static func cloneArguments(_ repository: String, destination: String) -> [String] {
    ["repo", "clone", repository, destination]
  }

  /// What the notice says when Clone…'s folder is there already.
  public static func existsMessage(_ destination: String) -> String {
    let name = (destination as NSString).lastPathComponent
    let parent = ((destination as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
    return "There's already a folder named \(name) in \(parent). Use Choose Folder… for it, or clone somewhere else."
  }

  /// The folder Clone… starts in and the launch looks inside: the one chosen last, else ~/Code when it's there.
  public static func cloneFolder(saved: String?, home: String, isDirectory: (String) -> Bool) -> String? {
    if let saved, isDirectory(saved) { return saved }
    let code = (home as NSString).appendingPathComponent("Code")
    return isDirectory(code) ? code : nil
  }
}
