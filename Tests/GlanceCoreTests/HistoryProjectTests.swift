import Testing
@testable import GlanceCore

private let root = "/Users/me/Code/app"

private func contains(_ cwd: String, folders: Set<String> = [], git: [String: HistoryProject.GitEntry] = [:]) -> Bool {
  HistoryProject.contains(cwd: cwd, root: root, home: "/Users/me",
                          exists: { folders.contains($0) }, git: { git[$0] })
}

@Test func theRootAndItsSubfoldersBelongToTheProject() {
  #expect(contains("/Users/me/Code/app"))
  #expect(contains("/Users/me/Code/app/terminal/macos"))
  #expect(contains("/Users/me/Code/app/.claude/worktrees/fix-x"))
}

@Test func aSiblingThatSharesTheNameIsNotTheProject() {
  let folders: Set<String> = ["/Users/me/Code/app-site"]
  let git: [String: HistoryProject.GitEntry] = ["/Users/me/Code/app-site": .repository]
  #expect(!contains("/Users/me/Code/app-site", folders: folders, git: git))
  #expect(!contains("/Users/me/Code/apple", folders: ["/Users/me/Code/apple"]))
}

@Test func aLiveWorktreeOfTheRepositoryBelongsWhereverItIs() {
  let folders: Set<String> = ["/Users/me/elsewhere/feature", "/Users/me/elsewhere/feature/src"]
  let git: [String: HistoryProject.GitEntry] = [
    "/Users/me/elsewhere/feature": .worktree(gitdir: "/Users/me/Code/app/.git/worktrees/feature"),
  ]
  #expect(contains("/Users/me/elsewhere/feature", folders: folders, git: git))
  #expect(contains("/Users/me/elsewhere/feature/src", folders: folders, git: git))
}

@Test func aWorktreeOfAnotherRepositoryDoesNot() {
  let folders: Set<String> = ["/Users/me/Code/app-other"]
  let git: [String: HistoryProject.GitEntry] = [
    "/Users/me/Code/app-other": .worktree(gitdir: "/Users/me/Code/other/.git/worktrees/app-other"),
  ]
  #expect(!contains("/Users/me/Code/app-other", folders: folders, git: git))
}

@Test func aRemovedSiblingNamedAfterTheProjectCountsAsOneOfItsWorktrees() {
  #expect(contains("/Users/me/Code/app-history-scope"))
  #expect(contains("/Users/me/Code/app-history-scope/terminal"))
  #expect(!contains("/Users/me/Code/apple"))
  #expect(!contains("/Users/me/Elsewhere/app-x"))
}

@Test func onlyTranscriptFoldersSpelledLikeTheProjectAreRead() {
  let names = ["-Users-me-Code-app", "-Users-me-Code-app-terminal", "-Users-me-Code-app-site", "-Users-me-Code-other"]
  #expect(HistoryProject.candidates(names, root: root) == Array(names.prefix(3)))
}

@Test func thePlaceNamesTheSubfolderOrWorktree() {
  #expect(HistoryProject.place(cwd: root, root: root) == nil)
  #expect(HistoryProject.place(cwd: root + "/terminal/macos", root: root) == "terminal/macos")
  #expect(HistoryProject.place(cwd: "/Users/me/Code/app-history-scope", root: root) == "app-history-scope")
}

@Test func theCwdIsReadFromTheFirstEntryThatHasOne() {
  let jsonl = """
  {"type":"file-history-snapshot","messageId":"a"}
  {"type":"user","cwd":"/Users/me/Code/app/terminal","message":{"role":"user","content":"hi"}}
  """
  #expect(HistoryProject.cwd(jsonl: jsonl) == "/Users/me/Code/app/terminal")
  #expect(HistoryProject.cwd(jsonl: "{\"type\":\"summary\"}") == nil)
}
