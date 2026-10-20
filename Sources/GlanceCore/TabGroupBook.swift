import Foundation

/// The Terminal side bar's groups and which group each tab is in (spec 2026-10-11-tab-groups-design.md). A value: the
/// app keeps one keyed by tab window (`TabGroups`), the tests one keyed by string.
public struct TabGroupBook<ID: Hashable> {
  public private(set) var groups: [UUID: TabGroupInfo]
  public private(set) var membership: [ID: UUID] = [:]

  /// Starts from the saved groups; no tab is in one until it's assigned (a restored tab, a new group).
  public init(groups saved: [TabGroupInfo] = []) {
    groups = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }

  /// The group `tab` is in, while that group exists.
  public func group(of tab: ID) -> UUID? {
    guard let id = membership[tab], groups[id] != nil else { return nil }
    return id
  }

  /// Every group defined, in a stable order: what's saved after each change.
  public var all: [TabGroupInfo] {
    groups.values.sorted { $0.id.uuidString < $1.id.uuidString }
  }

  /// The groups some tab is in: what's kept at quit.
  public var inUse: [TabGroupInfo] {
    let used = Set(membership.values)
    return all.filter { used.contains($0.id) }
  }

  /// Makes a group holding `tab` (out of any group it was in), named after the names in use.
  @discardableResult
  public mutating func newGroup(with tab: ID) -> UUID {
    let info = TabGroupInfo(name: Self.defaultName(taken: Set(inUse.map(\.name))))
    groups[info.id] = info
    membership[tab] = info.id
    return info.id
  }

  /// Puts `tab` in `group`; nil, or a group that doesn't exist, leaves it ungrouped.
  public mutating func assign(_ tab: ID, to group: UUID?) {
    if let group, groups[group] != nil {
      membership[tab] = group
    } else {
      membership[tab] = nil
    }
  }

  /// Renames a group; an empty or blank name keeps the old one.
  public mutating func rename(_ group: UUID, to name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, groups[group] != nil else { return }
    groups[group]?.name = trimmed
  }

  public mutating func setCollapsed(_ group: UUID, _ collapsed: Bool) {
    groups[group]?.isCollapsed = collapsed
  }

  /// Ungroup: every tab leaves the group, and the group goes.
  public mutating func dissolve(_ group: UUID) {
    membership = membership.filter { $0.value != group }
    groups[group] = nil
  }

  /// Forgets the tabs that aren't open any more.
  public mutating func keep(only open: Set<ID>) {
    membership = membership.filter { open.contains($0.key) }
  }

  /// "Group", then "Group 2", "Group 3"…: the first one not taken.
  public static func defaultName(taken: Set<String>) -> String {
    guard taken.contains("Group") else { return "Group" }
    var number = 2
    while taken.contains("Group \(number)") { number += 1 }
    return "Group \(number)"
  }
}
