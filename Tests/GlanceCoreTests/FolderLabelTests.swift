import Testing
@testable import GlanceCore

private let home = "/Users/me"

@Test func aFolderShowsItsLastComponent() {
  #expect(FolderLabel.name(forPath: "/Users/me/Code/glance", home: home) == "glance")
  #expect(FolderLabel.name(forPath: "/Users/me/Code/glance/", home: home) == "glance")
  #expect(FolderLabel.name(forPath: "~/Code/app", home: home) == "app")
}

@Test func homeAndRootHaveTheirOwnNames() {
  #expect(FolderLabel.name(forPath: "/Users/me", home: home) == "~")
  #expect(FolderLabel.name(forPath: "~", home: home) == "~")
  #expect(FolderLabel.name(forPath: "/", home: home) == "/")
}

@Test func unknownFoldersAreBlank() {
  #expect(FolderLabel.name(forPath: nil, home: home) == "")
  #expect(FolderLabel.name(forPath: "", home: home) == "")
}
