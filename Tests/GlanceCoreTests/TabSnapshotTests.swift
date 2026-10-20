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
