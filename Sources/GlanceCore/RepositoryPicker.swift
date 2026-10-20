import Foundation

/// The repository picker's list (spec 2026-10-08-pr-repositories-design.md, "The picker"): THIS TAB, RECENT and ALL
/// REPOSITORIES, or one list of matches while filtering; and RECENT after a pick.
public enum RepositoryPicker {
  public enum Section: Equatable, Sendable {
    case thisTab, recent, all
    /// The filter's matches, in one list.
    case matches
  }

  public struct Group: Equatable, Sendable {
    public let section: Section
    public let repositories: [GitHubAccount.Repository]
  }

  /// RECENT keeps this many.
  public static let recentLimit = 5

  /// The groups to show, empty ones left out. `all` is the account's list (newest push first), `recent` the picks
  /// (newest first), `thisTab` the tab's project on GitHub; a repository missing from `all` (not read yet, or out of
  /// reach) shows by name. With a filter: one list of everything known that matches, each once, names starting with
  /// the text first, then the other matches, each by last push.
  public static func groups(all: [GitHubAccount.Repository], recent: [String], thisTab: String?, filter: String)
    -> [Group] {
    let byKey = Dictionary(all.map { (RepositoryFolders.key($0.name), $0) }, uniquingKeysWith: { first, _ in first })
    func lookup(_ name: String) -> GitHubAccount.Repository {
      byKey[RepositoryFolders.key(name)] ?? GitHubAccount.Repository(name: name)
    }
    let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
    guard query.isEmpty else {
      var seen: Set<String> = []
      let known = (([thisTab].compactMap { $0 } + recent).map(lookup) + all)
        .filter { seen.insert(RepositoryFolders.key($0.name)).inserted }
      let matching = known.filter { matches($0, filter: query) }
      let starting = matching.filter { starts($0, query: query) }.sorted(by: GitHubAccount.newerFirst)
      let others = matching.filter { !starts($0, query: query) }.sorted(by: GitHubAccount.newerFirst)
      return [Group(section: .matches, repositories: starting + others)].filter { !$0.repositories.isEmpty }
    }
    return [
      Group(section: .thisTab, repositories: [thisTab].compactMap { $0 }.map(lookup)),
      Group(section: .recent, repositories: recent.map(lookup)),
      Group(section: .all, repositories: all),
    ].filter { !$0.repositories.isEmpty }
  }

  /// Whether `repository` passes the filter: its "owner/name" contains the text, ignoring case and the spaces around it.
  public static func matches(_ repository: GitHubAccount.Repository, filter: String) -> Bool {
    let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
    return query.isEmpty || repository.name.lowercased().contains(query)
  }

  /// The name, the owner or the whole "owner/name" starts with `query` (lowercased).
  static func starts(_ repository: GitHubAccount.Repository, query: String) -> Bool {
    let name = repository.name.lowercased()
    return name.hasPrefix(query) || name.split(separator: "/").contains { $0.hasPrefix(query) }
  }

  /// RECENT after picking `repository`: it first, then the others without it (ignoring case), at most five.
  public static func recent(after repository: String, in recent: [String]) -> [String] {
    let key = RepositoryFolders.key(repository)
    return Array(([repository] + recent.filter { RepositoryFolders.key($0) != key }).prefix(recentLimit))
  }
}
