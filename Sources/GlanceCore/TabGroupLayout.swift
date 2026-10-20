import Foundation

/// A named group of terminal tabs in the Terminal side bar (spec 2026-10-11-tab-groups-design.md).
public struct TabGroupInfo: Codable, Hashable, Sendable, Identifiable {
  public let id: UUID
  public var name: String
  /// Folded: the side bar shows the header and the group's tabs as chips.
  public var isCollapsed: Bool

  public init(id: UUID = UUID(), name: String, isCollapsed: Bool = false) {
    self.id = id
    self.name = name
    self.isCollapsed = isCollapsed
  }
}

/// How the Terminal side bar lays out grouped tabs. Its order is the tab order: a group is a run of tabs next to each
/// other, under its header. Generic over a tab's ID (its window in the app, a string in the tests). Every offset is a
/// `TabSidebarModel.move` offset: the index to insert before, counted before the tab leaves its place.
public enum TabGroupLayout {
  /// A run of tabs under one group's header, or ungrouped (`group == nil`).
  public struct Section<ID: Hashable>: Equatable {
    public let group: TabGroupInfo?
    public let tabs: [ID]

    public init(group: TabGroupInfo?, tabs: [ID]) {
      self.group = group
      self.tabs = tabs
    }
  }

  /// One thing the side bar draws, top to bottom: a group's header (its tabs as chips under it when folded) or a row.
  public enum Item<ID: Hashable>: Hashable {
    case header(UUID)
    case tab(ID)
  }

  /// A tab to move and where to.
  public struct Move<ID: Hashable>: Equatable {
    public let tab: ID
    public let toOffset: Int

    public init(tab: ID, toOffset: Int) {
      self.tab = tab
      self.toOffset = toOffset
    }
  }

  /// Where a dropped tab goes: its group (nil: ungrouped) and the offset to move it to.
  public struct Placement: Equatable {
    public let group: UUID?
    public let toOffset: Int

    public init(group: UUID?, toOffset: Int) {
      self.group = group
      self.toOffset = toOffset
    }
  }

  /// The group a tab counts as being in: its own, while that group exists.
  static func group<ID: Hashable>(of tab: ID, _ membership: [ID: UUID], _ groups: [UUID: TabGroupInfo]) -> UUID? {
    guard let id = membership[tab], groups[id] != nil else { return nil }
    return id
  }

  /// The side bar's sections in tab order. A group split by a move (before `repair` has run) is drawn once, where its
  /// first tab is, so a header never shows twice.
  public static func sections<ID: Hashable>(_ tabs: [ID], membership: [ID: UUID],
                                            groups: [UUID: TabGroupInfo]) -> [Section<ID>] {
    var result: [(group: TabGroupInfo?, tabs: [ID])] = []
    var at: [UUID: Int] = [:]
    for tab in tabs {
      if let id = group(of: tab, membership, groups), let info = groups[id] {
        if let index = at[id] {
          result[index].tabs.append(tab)
        } else {
          at[id] = result.count
          result.append((info, [tab]))
        }
      } else if let last = result.indices.last, result[last].group == nil {
        result[last].tabs.append(tab)
      } else {
        result.append((nil, [tab]))
      }
    }
    return result.map { Section(group: $0.group, tabs: $0.tabs) }
  }

  /// What the side bar draws: each group's header, the rows of ungrouped tabs and of open groups.
  public static func items<ID: Hashable>(_ sections: [Section<ID>]) -> [Item<ID>] {
    sections.flatMap { section -> [Item<ID>] in
      guard let info = section.group else { return section.tabs.map { .tab($0) } }
      return [.header(info.id)] + (info.isCollapsed ? [] : section.tabs.map { .tab($0) })
    }
  }

  /// The next move that brings a split group back together: its first tab found after the group's first run goes just
  /// after that run. Nil when every group is one run. Apply it, then ask again.
  public static func repair<ID: Hashable>(_ tabs: [ID], membership: [ID: UUID],
                                          groups: [UUID: TabGroupInfo]) -> Move<ID>? {
    var runEnd: [UUID: Int] = [:]
    var closed: Set<UUID> = []
    var current: UUID?
    for (index, tab) in tabs.enumerated() {
      let id = group(of: tab, membership, groups)
      if id != current, let current { closed.insert(current) }
      if let id {
        if closed.contains(id), let end = runEnd[id] { return Move(tab: tab, toOffset: end) }
        runEnd[id] = index + 1
      }
      current = id
    }
    return nil
  }

  /// Where a tab joins `group`: just after the group's last tab. Nil when no tab is in the group.
  public static func joinOffset<ID: Hashable>(group id: UUID, tabs: [ID], membership: [ID: UUID]) -> Int? {
    tabs.lastIndex { membership[$0] == id }.map { $0 + 1 }
  }

  /// Where a dragged tab goes when it's let go just below `above` (nil: at the very top). It joins the section above
  /// it: a tab's own section, or the group of a header (first in an open group, last in a folded one).
  public static func drop<ID: Hashable>(below above: Item<ID>?, tabs: [ID], membership: [ID: UUID],
                                        groups: [UUID: TabGroupInfo]) -> Placement {
    switch above {
    case nil:
      return Placement(group: nil, toOffset: 0)
    case .tab(let tab):
      guard let index = tabs.firstIndex(of: tab) else { return Placement(group: nil, toOffset: tabs.count) }
      return Placement(group: group(of: tab, membership, groups), toOffset: index + 1)
    case .header(let id):
      guard let info = groups[id] else { return Placement(group: nil, toOffset: 0) }
      let mine = tabs.indices.filter { group(of: tabs[$0], membership, groups) == id }
      guard let first = mine.first, let last = mine.last else { return Placement(group: id, toOffset: tabs.count) }
      return Placement(group: id, toOffset: info.isCollapsed ? last + 1 : first)
    }
  }
}
