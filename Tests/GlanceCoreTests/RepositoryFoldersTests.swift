import Foundation
import Testing
@testable import GlanceCore

@Test func aFolderServesEveryRepositoryAmongItsRemotesWhateverTheCase() {
  var map = RepositoryFolders()
  map.record("/code/ghostty", for: ["ghostty-org/ghostty", "me/ghostty"], replacing: false)
  #expect(map.folder(for: "Ghostty-Org/Ghostty") == "/code/ghostty")
  #expect(map.folder(for: "me/ghostty") == "/code/ghostty")
  #expect(map.folder(for: "me/other") == nil)
}

@Test func foundFoldersDontMoveOnesAlreadyRecordedButCloneAndChooseDo() {
  var map = RepositoryFolders(["o/r": "/first"])
  map.record("/second", for: ["O/R"], replacing: false)
  #expect(map.folder(for: "o/r") == "/first")
  map.record("/chosen", for: ["o/r"], replacing: true)
  #expect(map.folder(for: "o/r") == "/chosen")
  map.remove("O/R")
  #expect(map.folder(for: "o/r") == nil)
}

@Test func savedKeysAreLowercasedWhenTheMapIsMade() {
  #expect(RepositoryFolders(["Gobinda168/Glance": "/g"]).folders == ["gobinda168/glance": "/g"])
}

@Test func theLaunchCheckDropsFoldersThatWentAwayOrLostTheRemote() {
  let map = RepositoryFolders(["a/a": "/gone", "b/b": "/moved", "c/c": "/kept", "d/d": "/kept"])
  let checked = map.checked { folder -> [String]? in
    switch folder {
    case "/moved": ["x/x"]
    case "/kept": ["C/C", "d/d"]
    default: nil
    }
  }
  #expect(checked == RepositoryFolders(["c/c": "/kept", "d/d": "/kept"]))
}

@Test func aTabsOwnFolderWinsForItsRepository() {
  let map = RepositoryFolders(["o/r": "/clone"])
  #expect(map.folder(for: "o/r", own: "/worktree", ownRepositories: ["O/R"]) == "/worktree")
  #expect(map.folder(for: "o/r", own: "/elsewhere", ownRepositories: ["x/y"]) == "/clone")
  #expect(map.folder(for: "o/r", own: nil, ownRepositories: []) == "/clone")
}

@Test func chooseFolderTakesAFolderOnlyWhenOneOfItsRemotesIsTheRepository() {
  #expect(RepositoryFolders.choice(for: "o/r", remotes: ["up/r", "O/R"]) == .accepted)
  #expect(RepositoryFolders.choice(for: "o/r", remotes: ["x/y"]) == .otherRepository("x/y"))
  #expect(RepositoryFolders.choice(for: "o/r", remotes: []) == .notGitHub)
  #expect(RepositoryFolders.message(.accepted) == nil)
  #expect(RepositoryFolders.message(.otherRepository("x/y")) == "That folder is x/y on GitHub.")
  #expect(RepositoryFolders.message(.notGitHub) == "That folder isn't a GitHub repository.")
}

@Test func cloneMakesAFolderNamedAfterTheRepository() {
  #expect(RepositoryFolders.cloneDestination("gobinda168/glance", parent: "/Users/me/Code") == "/Users/me/Code/glance")
  #expect(RepositoryFolders.cloneArguments("gobinda168/glance", destination: "/Users/me/Code/glance")
    == ["repo", "clone", "gobinda168/glance", "/Users/me/Code/glance"])
  #expect(RepositoryFolders.existsMessage("/Volumes/Work/glance")
    == "There's already a folder named glance in /Volumes/Work. Use Choose Folder… for it, or clone somewhere else.")
}

@Test func theCloneFolderIsTheLastOneElseCodeInHome() {
  let folders: Set<String> = ["/Users/me/Code", "/Volumes/Work"]
  #expect(RepositoryFolders.cloneFolder(saved: "/Volumes/Work", home: "/Users/me", isDirectory: folders.contains)
    == "/Volumes/Work")
  #expect(RepositoryFolders.cloneFolder(saved: "/gone", home: "/Users/me", isDirectory: folders.contains)
    == "/Users/me/Code")
  #expect(RepositoryFolders.cloneFolder(saved: nil, home: "/Users/other", isDirectory: folders.contains) == nil)
}
