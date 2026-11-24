import Foundation

/// The tabs Glance Studio had open when it last ran, saved so a relaunch (an update restarts the whole app) opens where
/// the user left off, as a browser does. Terminal tabs are brought back by AppKit's own window restoration (they only
/// name the terminal's first pane here, to put them in order); every other tab says what it showed.
public struct TabSnapshot: Codable, Equatable, Sendable {
  public struct Tab: Codable, Equatable, Sendable {
    /// `"terminal"`, or a Glance tab's kind (`GlanceTabController.tabKind`).
    public var kind: String
    /// What identifies the tab within its kind: an editor's folder, a pull request's `repository#number`.
    public var key: String?
    /// A Browser tab's page.
    public var url: String?
    /// A terminal tab's first pane (its surface ID, which restoration keeps).
    public var surface: String?

    public init(kind: String, key: String? = nil, url: String? = nil, surface: String? = nil) {
      self.kind = kind
      self.key = key
      self.url = url
      self.surface = surface
    }

    public static let terminal = "terminal"
    public var isTerminal: Bool { kind == Self.terminal }
  }

  /// One window's tabs, left to right.
  public struct Group: Codable, Equatable, Sendable {
    public var tabs: [Tab]
    /// The tab in front, as an index into `tabs`.
    public var selected: Int?

    public init(tabs: [Tab], selected: Int? = nil) {
      self.tabs = tabs
      self.selected = selected
    }

    /// `selected` when it names a tab.
    public var front: Int? { selected.flatMap { tabs.indices.contains($0) ? $0 : nil } }
  }

  public static let version = 1

  public var version = Self.version
  public var groups: [Group]
  /// The window the user was in, as an index into `groups`.
  public var frontGroup: Int?

  public init(groups: [Group], frontGroup: Int? = nil) {
    self.groups = groups
    self.frontGroup = frontGroup
  }

  public var isEmpty: Bool { groups.allSatisfy { $0.tabs.isEmpty } }

  /// What to open: one window per terminal window that came back (`isLive` says which, by surface ID), and every other tab
  /// inside one of them, as a tab with no terminal of its own would otherwise come back as a window of its own, be saved
  /// as one, and do so at every launch. Loose tabs join the window the user was in, else the first with a terminal, else
  /// the first; one a window already has isn't added twice. The tab in front stays in front.
  public func folded(isLive: (String) -> Bool) -> TabSnapshot {
    let kept = groups.map { group -> Group in
      var tabs: [Tab] = [], shown: Int?
      for (index, tab) in group.tabs.enumerated() where !tab.isTerminal || (tab.surface.map(isLive) ?? false) {
        if index == group.front { shown = tabs.count }
        tabs.append(tab)
      }
      return Group(tabs: tabs, selected: shown)
    }
    let hasTerminal = kept.map { $0.tabs.contains(where: \.isTerminal) }
    let wanted = frontGroup.flatMap { kept.indices.contains($0) && hasTerminal[$0] ? $0 : nil }
    guard let target = wanted ?? hasTerminal.firstIndex(of: true) ?? kept.firstIndex(where: { !$0.tabs.isEmpty }) else {
      return TabSnapshot(groups: [])
    }
    var home = kept[target]
    for (index, group) in kept.enumerated() where index != target && !hasTerminal[index] {
      for tab in group.tabs where !home.tabs.contains(tab) { home.tabs.append(tab) }
      // The user was in this loose window: its tab in front is now the home window's.
      if index == frontGroup, let shown = group.front, let at = home.tabs.firstIndex(of: group.tabs[shown]) {
        home.selected = at
      }
    }
    var result: [Group] = [], front: Int?, homeSlot = 0
    for (index, group) in kept.enumerated() where index == target || hasTerminal[index] {
      if index == target { homeSlot = result.count }
      if index == frontGroup { front = result.count }
      result.append(index == target ? home : group)
    }
    return TabSnapshot(groups: result, frontGroup: frontGroup == nil ? nil : front ?? homeSlot)
  }

  public func encoded() -> Data? { try? JSONEncoder().encode(self) }

  /// The snapshot in `data`; nil for anything unreadable or from a version this one doesn't know.
  public static func decode(_ data: Data?) -> TabSnapshot? {
    guard let data, let snapshot = try? JSONDecoder().decode(TabSnapshot.self, from: data),
      snapshot.version == Self.version else { return nil }
    return snapshot
  }
}
