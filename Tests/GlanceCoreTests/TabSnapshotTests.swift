import Foundation
import Testing
@testable import GlanceCore

@Test func aSnapshotSurvivesBeingSaved() {
  let snapshot = TabSnapshot(
    groups: [
      .init(tabs: [
        .init(kind: "terminal", surface: "6F1C2D3E-4A5B-4C6D-8E7F-0123456789AB"),
        .init(kind: "browser", url: "https://example.com/a"),
        .init(kind: "razor", key: "/Users/me/app"),
      ], selected: 1)
    ],
    frontGroup: 0)
  #expect(TabSnapshot.decode(snapshot.encoded()) == snapshot)
}

@Test func anUnreadableOrNewerSnapshotIsIgnored() {
  #expect(TabSnapshot.decode(nil) == nil)
  #expect(TabSnapshot.decode(Data("nope".utf8)) == nil)
  var future = TabSnapshot(groups: [])
  future.version = 99
  #expect(TabSnapshot.decode(future.encoded()) == nil)
}

@Test func theFrontTabIsOnlyOneThatExists() {
  let tabs = [TabSnapshot.Tab(kind: "home"), .init(kind: "tickets")]
  #expect(TabSnapshot.Group(tabs: tabs, selected: 1).front == 1)
  #expect(TabSnapshot.Group(tabs: tabs, selected: 5).front == nil)
  #expect(TabSnapshot.Group(tabs: tabs, selected: nil).front == nil)
  #expect(TabSnapshot(groups: [.init(tabs: [])]).isEmpty)
}

private func terminal(_ id: String) -> TabSnapshot.Tab { .init(kind: "terminal", surface: id) }
private func razor(_ root: String) -> TabSnapshot.Tab { .init(kind: "razor", key: root) }

@Test func aWindowWithoutATerminalJoinsTheWindowTheUserWasIn() {
  let snapshot = TabSnapshot(groups: [
    .init(tabs: [terminal("a"), .init(kind: "home")]),
    .init(tabs: [terminal("b"), terminal("c")], selected: 1),
    .init(tabs: [razor("/x")], selected: 0),
    .init(tabs: [.init(kind: "studio", key: "/y")], selected: 0),
  ], frontGroup: 1)
  let folded = snapshot.folded { _ in true }
  #expect(folded.groups == [
    .init(tabs: [terminal("a"), .init(kind: "home")]),
    .init(tabs: [terminal("b"), terminal("c"), razor("/x"), .init(kind: "studio", key: "/y")], selected: 1),
  ])
  #expect(folded.frontGroup == 1)
}

@Test func theSameEditorInSeveralLooseWindowsBecomesOneTab() {
  let snapshot = TabSnapshot(groups: [
    .init(tabs: [terminal("a"), razor("/x")]),
    .init(tabs: [razor("/x")]),
    .init(tabs: [razor("/y")]),
    .init(tabs: [razor("/y")]),
  ], frontGroup: 0)
  #expect(snapshot.folded { _ in true }.groups == [.init(tabs: [terminal("a"), razor("/x"), razor("/y")])])
}

@Test func twoEditorsOnOneFolderInOneWindowStay() {
  // New Editor Tab makes these on purpose.
  let group = TabSnapshot.Group(tabs: [terminal("a"), razor("/x"), razor("/x")], selected: 2)
  #expect(TabSnapshot(groups: [group], frontGroup: 0).folded { _ in true }.groups == [group])
}

@Test func aTerminalThatDidNotComeBackLeavesNoWindowOfItsOwn() {
  let snapshot = TabSnapshot(groups: [
    .init(tabs: [terminal("a")], selected: 0),
    .init(tabs: [razor("/x"), terminal("gone")], selected: 1),
  ], frontGroup: 0)
  let folded = snapshot.folded { $0 == "a" }
  #expect(folded.groups == [.init(tabs: [terminal("a"), razor("/x")], selected: 0)])
}

@Test func theTabInFrontStaysInFrontWhenItsWindowIsFolded() {
  let snapshot = TabSnapshot(groups: [
    .init(tabs: [terminal("a")], selected: 0),
    .init(tabs: [razor("/x"), razor("/y")], selected: 1),
  ], frontGroup: 1)
  let folded = snapshot.folded { _ in true }
  #expect(folded.groups == [.init(tabs: [terminal("a"), razor("/x"), razor("/y")], selected: 2)])
  #expect(folded.frontGroup == 0)
}

@Test func withNoTerminalAtAllTheFirstWindowTakesEveryTab() {
  let snapshot = TabSnapshot(groups: [
    .init(tabs: [razor("/x")], selected: 0),
    .init(tabs: [terminal("gone")], selected: 0),
    .init(tabs: [razor("/y")], selected: 0),
  ], frontGroup: 2)
  let folded = snapshot.folded { _ in false }
  #expect(folded.groups == [.init(tabs: [razor("/x"), razor("/y")], selected: 1)])
  #expect(folded.frontGroup == 0)
}

@Test func anEmptySnapshotStaysEmpty() {
  #expect(TabSnapshot(groups: []).folded { _ in true }.groups.isEmpty)
  #expect(TabSnapshot(groups: [.init(tabs: [terminal("gone")])]).folded { _ in false }.isEmpty)
}
