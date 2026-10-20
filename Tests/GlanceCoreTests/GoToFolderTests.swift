import Testing
@testable import GlanceCore

@Test func goToFolderQuotesThePathAsOneWord() {
  #expect(GoToFolder.command(path: "/Users/me/Code/glance") == "cd -- '/Users/me/Code/glance'")
  #expect(GoToFolder.command(path: "/Users/me/My Work/it's") == #"cd -- '/Users/me/My Work/it'\''s'"#)
}

@Test func goToFolderOnlyTypesIntoAnIdleShell() {
  #expect(GoToFolder.canType(runningCommand: nil))
  #expect(!GoToFolder.canType(runningCommand: "claude"))
}
