import Foundation
import Testing
@testable import GlanceCore

private let home = "/Users/me"

@Test func withoutAFilterThePaletteShowsThisTabThenRecent() {
  let groups = EditorFolderPicker.groups(thisTab: "/Users/me/Code/glance",
                                         recent: ["/Users/me/Code/glance", "/Users/me/Code/site", "/work/api"],
                                         filter: "", home: home)
  #expect(groups.map(\.section) == [.thisTab, .recent])
  #expect(groups[0].folders == ["/Users/me/Code/glance"])
  #expect(groups[1].folders == ["/Users/me/Code/site", "/work/api"]) // this tab's project isn't listed twice
}

@Test func emptySectionsAreLeftOutOfThePalette() {
  #expect(EditorFolderPicker.groups(thisTab: nil, recent: [], filter: "", home: home).isEmpty)
  #expect(EditorFolderPicker.groups(thisTab: nil, recent: ["/a/b"], filter: "", home: home).map(\.section) == [.recent])
}

@Test func recentKeepsAtMostItsLimit() {
  let recent = (0..<20).map { "/p/\($0)" }
  let groups = EditorFolderPicker.groups(thisTab: nil, recent: recent, filter: "", home: home)
  #expect(groups[0].folders.count == EditorFolderPicker.recentLimit)
}

@Test func filteringMergesIntoOneListWithNameStartsFirst() {
  let groups = EditorFolderPicker.groups(thisTab: "/Users/me/Code/my-site",
                                         recent: ["/Users/me/Code/glance", "/Users/me/Code/site-kit", "/x/api"],
                                         filter: " SITE ", home: home)
  #expect(groups.map(\.section) == [.matches])
  #expect(groups[0].folders == ["/Users/me/Code/site-kit", "/Users/me/Code/my-site"])
}

@Test func theFilterMatchesTheWholePathAsShownWithTheTilde() {
  let groups = EditorFolderPicker.groups(thisTab: nil, recent: ["/Users/me/Code/glance", "/x/api"], filter: "~/code",
                                         home: home)
  #expect(groups[0].folders == ["/Users/me/Code/glance"])
}

@Test func aNewFolderNeedsAPlainName() {
  let none: (String) -> Bool = { _ in false }
  #expect(EditorFolderPicker.newFolder(named: "  ", in: "/p", exists: none) == .empty)
  if case .invalid = EditorFolderPicker.newFolder(named: "a/b", in: "/p", exists: none) {} else { Issue.record("slash") }
  if case .invalid = EditorFolderPicker.newFolder(named: "a:b", in: "/p", exists: none) {} else { Issue.record("colon") }
  if case .invalid = EditorFolderPicker.newFolder(named: ".hidden", in: "/p", exists: none) {} else { Issue.record("dot") }
  if case .invalid = EditorFolderPicker.newFolder(named: "..", in: "/p", exists: none) {} else { Issue.record("dots") }
  let long = String(repeating: "a", count: 256)
  if case .invalid = EditorFolderPicker.newFolder(named: long, in: "/p", exists: none) {} else { Issue.record("long") }
}

@Test func aNewFolderIsTheTrimmedNameInItsParent() {
  #expect(EditorFolderPicker.newFolder(named: " my app ", in: "/p", exists: { _ in false }) == .create("/p/my app"))
}

@Test func anExistingFolderIsNeverCreatedAgain() {
  #expect(EditorFolderPicker.newFolder(named: "glance", in: "/p", exists: { $0 == "/p/glance" }) == .exists("/p/glance"))
}
