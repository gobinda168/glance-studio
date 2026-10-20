import Testing
@testable import GlanceCore

@Test func aFolderIsOwnedWhenATerminalSitsInItOrBelowOrAbove() {
  let terminals = ["/Users/u/code/app", "/Users/u/notes"]
  #expect(FolderOwnership.isOwned("/Users/u/code/app", by: terminals))
  #expect(FolderOwnership.isOwned("/Users/u/code/app/", by: terminals))      // trailing slash
  #expect(FolderOwnership.isOwned("/Users/u/code", by: terminals))           // Claude at the root, shell cd'd deeper
  #expect(FolderOwnership.isOwned("/Users/u/code/app/src", by: terminals))   // shell at the root, Claude deeper
}

@Test func otherFoldersAndLookalikesAreNotOwned() {
  let terminals = ["/Users/u/code/app"]
  #expect(!FolderOwnership.isOwned("/Users/u/code/app2", by: terminals))     // a sibling with the same prefix
  #expect(!FolderOwnership.isOwned("/Users/u/other", by: terminals))
  #expect(!FolderOwnership.isOwned("/Users/u/code/app", by: []))
}

@Test func emptyFoldersNeverMatch() {
  #expect(!FolderOwnership.isOwned("/Users/u/code", by: [""]))
  #expect(!FolderOwnership.isOwned("", by: ["/Users/u/code"]))
}
