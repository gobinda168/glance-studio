import Foundation

/// What the Pull requests side bar shows (spec 2026-10-07-pr-manager-design.md, "Navigation → PR list"; its tabs, spec
/// 2026-10-12-pr-sidebar-tabs-design.md): its tabs, filter field and filter menu.
extension PullRequests {
  /// The filter field's text and the filter menu's choices.
  public struct Filter: Equatable, Sendable {
    public var text: String
    /// Show drafts.
    public var showsDrafts: Bool
    /// Failing checks only.
    public var failingOnly: Bool

    public init(text: String = "", showsDrafts: Bool = true, failingOnly: Bool = false) {
      self.text = text
      self.showsDrafts = showsDrafts
      self.failingOnly = failingOnly
    }

    /// A menu choice hides something: the filter button shows it.
    public var isNarrowed: Bool { !showsDrafts || failingOnly }
  }

  /// The pull requests of `list` that `filter` lets through:
  /// - the text matches (`matches`);
  /// - drafts only with Show drafts;
  /// - with Failing checks only, the ones whose checks fail (none of Merged: its checks no longer matter).
  public static func visible(_ pullRequests: [PullRequest], in list: List, filter: Filter) -> [PullRequest] {
    if list == .recentlyMerged, filter.failingOnly { return [] }
    return pullRequests.filter { pullRequest in
      matches(pullRequest, filter: filter.text)
        && (filter.showsDrafts || !pullRequest.isDraft)
        && (!filter.failingOnly || pullRequest.checks.state == .failing)
    }
  }

  /// A tab of the side bar: its list, and how many of its pull requests the filter lets through.
  public struct Tab: Equatable, Sendable {
    public let list: List
    public let count: Int
  }

  /// The side bar's tabs, To review, Yours and Merged: all three always, each counting what the filter leaves it, so a
  /// filter shows where its matches are.
  public static func tabs(_ board: Board, filter: Filter) -> [Tab] {
    List.allCases.map { Tab(list: $0, count: visible(board.pullRequests($0), in: $0, filter: filter).count) }
  }

  /// What a tab with no rows says: why the filter emptied it, else what the list holds.
  public static func emptyText(_ list: List, filter: Filter) -> String {
    let text = filter.text.trimmingCharacters(in: .whitespaces)
    if !text.isEmpty { return "Nothing matches “\(text)”." }
    if filter.isNarrowed { return "Nothing matches the filter." }
    switch list {
    case .waitingOnYou: return "Nothing is waiting on your review."
    case .yours: return "You have no open pull requests."
    case .recentlyMerged: return "Nothing of yours merged recently."
    }
  }

  /// The tab to show for the pull request in front (#`number` of `repository`): `current` while it lists it, or while no
  /// tab does; else the first tab that lists it, so a pull request opened from anywhere shows selected.
  public static func tab(_ current: List, showing number: Int, of repository: String, in board: Board) -> List {
    let key = RepositoryFolders.key(repository)
    func lists(_ list: List) -> Bool {
      board.pullRequests(list).contains { $0.number == number && RepositoryFolders.key($0.repository) == key }
    }
    if lists(current) { return current }
    return List.allCases.first(where: lists) ?? current
  }
}

extension PullRequests.List {
  /// Its tab's name.
  public var title: String {
    switch self {
    case .waitingOnYou: "To review"
    case .yours: "Yours"
    case .recentlyMerged: "Merged"
    }
  }
}
