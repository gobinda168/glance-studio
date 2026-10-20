import Foundation
import Testing
@testable import GlanceCore

@Test func newGroupsAreNamedAfterTheNamesInUse() {
  var book = TabGroupBook<String>()
  let first = book.newGroup(with: "1")
  let second = book.newGroup(with: "2")
  #expect(book.groups[first]?.name == "Group")
  #expect(book.groups[second]?.name == "Group 2")
  // Once no tab is in "Group", the name is free again.
  book.assign("1", to: second)
  let third = book.newGroup(with: "3")
  #expect(book.groups[third]?.name == "Group")
  #expect(TabGroupBook<String>.defaultName(taken: ["Group", "Group 2", "Group 3"]) == "Group 4")
}

@Test func aNewGroupTakesTheTabOutOfItsOldOne() {
  var book = TabGroupBook<String>()
  let old = book.newGroup(with: "1")
  let new = book.newGroup(with: "1")
  #expect(book.group(of: "1") == new)
  #expect(book.inUse.map(\.id) == [new])
  #expect(Set(book.all.map(\.id)) == [old, new])
}

@Test func assigningAnUnknownGroupLeavesTheTabUngrouped() {
  var book = TabGroupBook<String>()
  let group = book.newGroup(with: "1")
  book.assign("2", to: UUID())
  #expect(book.group(of: "2") == nil)
  book.assign("1", to: nil)
  #expect(book.group(of: "1") == nil)
  book.assign("1", to: group)
  #expect(book.group(of: "1") == group)
}

@Test func renameTrimsAndIgnoresAnEmptyName() {
  var book = TabGroupBook<String>()
  let group = book.newGroup(with: "1")
  book.rename(group, to: "  Services \n")
  #expect(book.groups[group]?.name == "Services")
  book.rename(group, to: "   ")
  #expect(book.groups[group]?.name == "Services")
}

@Test func foldingIsKept() {
  var book = TabGroupBook<String>()
  let group = book.newGroup(with: "1")
  book.setCollapsed(group, true)
  #expect(book.groups[group]?.isCollapsed == true)
}

@Test func dissolvingUngroupsEveryTabAndDropsTheGroup() {
  var book = TabGroupBook<String>()
  let group = book.newGroup(with: "1")
  book.assign("2", to: group)
  book.dissolve(group)
  #expect(book.group(of: "1") == nil)
  #expect(book.group(of: "2") == nil)
  #expect(book.groups[group] == nil)
}

@Test func closedTabsAreForgottenAndTheirGroupsLeaveInUse() {
  var book = TabGroupBook<String>()
  let group = book.newGroup(with: "1")
  book.keep(only: ["2"])
  #expect(book.group(of: "1") == nil)
  #expect(book.inUse.isEmpty)
  #expect(book.all.map(\.id) == [group]) // still defined until the app saves only what's in use
}

@Test func savedGroupsComeBackWithoutTabsAndTakeRestoredOnes() {
  let saved = TabGroupInfo(name: "Services", isCollapsed: true)
  var book = TabGroupBook<String>(groups: [saved])
  #expect(book.all == [saved])
  #expect(book.inUse.isEmpty)
  book.assign("1", to: saved.id)
  #expect(book.inUse == [saved])
}

@Test func groupInfoRoundTripsThroughJSON() throws {
  let info = [TabGroupInfo(name: "Services", isCollapsed: true)]
  let data = try JSONEncoder().encode(info)
  #expect(try JSONDecoder().decode([TabGroupInfo].self, from: data) == info)
}
