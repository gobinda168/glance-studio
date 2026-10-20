import Foundation
import Testing
@testable import GlanceCore

private let a = TabGroupInfo(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!, name: "A")
private let b = TabGroupInfo(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!, name: "B")
private let both = [a.id: a, b.id: b]

private func folded(_ info: TabGroupInfo) -> TabGroupInfo {
  var info = info
  info.isCollapsed = true
  return info
}

// MARK: Sections and items

@Test func ungroupedTabsMakeOneSection() {
  #expect(TabGroupLayout.sections(["1", "2"], membership: [:], groups: both)
    == [.init(group: nil, tabs: ["1", "2"])])
}

@Test func groupsAndUngroupedRunsFollowTabOrder() {
  #expect(TabGroupLayout.sections(["1", "2", "3", "4"], membership: ["2": a.id, "3": a.id], groups: both)
    == [.init(group: nil, tabs: ["1"]), .init(group: a, tabs: ["2", "3"]), .init(group: nil, tabs: ["4"])])
}

@Test func aGroupThatNoLongerExistsCountsAsUngrouped() {
  #expect(TabGroupLayout.sections(["1", "2"], membership: ["2": UUID()], groups: both)
    == [.init(group: nil, tabs: ["1", "2"])])
}

@Test func aSplitGroupIsDrawnOnceAtItsFirstTab() {
  // [a 2 a]: before repair puts them together, the side bar still shows one A.
  #expect(TabGroupLayout.sections(["1", "2", "3"], membership: ["1": a.id, "3": a.id], groups: both)
    == [.init(group: a, tabs: ["1", "3"]), .init(group: nil, tabs: ["2"])])
}

@Test func itemsAreHeadersAndTheRowsOfOpenGroups() {
  let groups = [a.id: a, b.id: folded(b)]
  let sections = TabGroupLayout.sections(["1", "2", "3", "4"], membership: ["2": a.id, "3": b.id, "4": b.id],
                                         groups: groups)
  #expect(TabGroupLayout.items(sections) == [.tab("1"), .header(a.id), .tab("2"), .header(b.id)])
}

// MARK: Repair

@Test func contiguousGroupsNeedNoRepair() {
  #expect(TabGroupLayout.repair(["1", "2", "3"], membership: ["1": a.id, "2": a.id, "3": b.id], groups: both) == nil)
  #expect(TabGroupLayout.repair(["1", "2", "3"], membership: ["1": a.id, "3": b.id], groups: both) == nil)
}

@Test func aStragglerMovesBackAfterItsGroupsFirstRun() {
  // [a a 3 a]: the last a goes before 3.
  #expect(TabGroupLayout.repair(["1", "2", "3", "4"], membership: ["1": a.id, "2": a.id, "4": a.id], groups: both)
    == .init(tab: "4", toOffset: 2))
  // [a b a]: the second a goes before b.
  #expect(TabGroupLayout.repair(["1", "2", "3"], membership: ["1": a.id, "2": b.id, "3": a.id], groups: both)
    == .init(tab: "3", toOffset: 1))
}

@Test func repairingOneMoveAtATimeBringsEveryGroupTogether() throws {
  var tabs = ["1", "2", "3", "4", "5", "6"]
  let membership = ["1": a.id, "2": b.id, "3": a.id, "5": b.id, "6": a.id]
  var moves = 0
  while let move = TabGroupLayout.repair(tabs, membership: membership, groups: both), moves < 10 {
    let from = try #require(tabs.firstIndex(of: move.tab))
    let to = try #require(TabOrder.insertionIndex(from: from, toOffset: move.toOffset))
    tabs.insert(tabs.remove(at: from), at: to)
    moves += 1
  }
  #expect(moves == 3)
  #expect(TabGroupLayout.sections(tabs, membership: membership, groups: both).map(\.group?.id) == [a.id, b.id, nil])
}

// MARK: Joining and dropping

private let tabs = ["1", "2", "3", "4"] // 1 ungrouped, 2 and 3 in A, 4 in B
private let members = ["2": a.id, "3": a.id, "4": b.id]

private func drop(below item: TabGroupLayout.Item<String>?, groups: [UUID: TabGroupInfo] = both)
  -> TabGroupLayout.Placement {
  TabGroupLayout.drop(below: item, tabs: tabs, membership: members, groups: groups)
}

@Test func aTabJoinsAtTheEndOfItsGroup() {
  #expect(TabGroupLayout.joinOffset(group: a.id, tabs: tabs, membership: members) == 3)
  #expect(TabGroupLayout.joinOffset(group: b.id, tabs: tabs, membership: members) == 4)
  #expect(TabGroupLayout.joinOffset(group: UUID(), tabs: tabs, membership: members) == nil)
}

@Test func droppedAtTheTopIsUngroupedAndFirst() {
  #expect(drop(below: nil) == .init(group: nil, toOffset: 0))
}

@Test func droppedBelowATabJoinsThatTabsSection() {
  #expect(drop(below: .tab("1")) == .init(group: nil, toOffset: 1))
  #expect(drop(below: .tab("2")) == .init(group: a.id, toOffset: 2))
  // A group's last tab still counts as the group: dropping under it appends to the group.
  #expect(drop(below: .tab("3")) == .init(group: a.id, toOffset: 3))
}

@Test func droppedBelowAnOpenHeaderGoesFirstInTheGroup() {
  #expect(drop(below: .header(a.id)) == .init(group: a.id, toOffset: 1))
}

@Test func droppedBelowAFoldedHeaderGoesLastInTheGroup() {
  #expect(drop(below: .header(a.id), groups: [a.id: folded(a), b.id: b]) == .init(group: a.id, toOffset: 3))
}

@Test func droppedBelowTheHeaderOfAGroupThatIsGoneGoesToTheTop() {
  #expect(drop(below: .header(UUID())) == .init(group: nil, toOffset: 0))
}
