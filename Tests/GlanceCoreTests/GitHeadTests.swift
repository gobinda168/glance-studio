import Foundation
import Testing
@testable import GlanceCore

@Test func aBranchHeadNamesTheBranch() {
  #expect(GitHead.branch(fromHead: "ref: refs/heads/main\n") == "main")
  #expect(GitHead.branch(fromHead: "ref: refs/heads/feature/tab-sidebar") == "feature/tab-sidebar")
}

@Test func aDetachedHeadShowsTheShortHash() {
  #expect(GitHead.branch(fromHead: "0123456789abcdef0123456789abcdef01234567\n") == "0123456")
}

@Test func otherRefsAreShownAsTheyAre() {
  #expect(GitHead.branch(fromHead: "ref: refs/remotes/origin/x") == "refs/remotes/origin/x")
}

@Test func garbageAndEmptyHeadsHaveNoBranch() {
  #expect(GitHead.branch(fromHead: "hello") == nil)
  #expect(GitHead.branch(fromHead: "") == nil)
  #expect(GitHead.branch(fromHead: "ref:") == nil)
  #expect(GitHead.branch(fromHead: "abc") == nil) // too short to be a hash
}

private func makeDir(_ files: [String: String]) throws -> String {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glance-git-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  for (path, content) in files {
    let url = dir.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: url, atomically: true, encoding: .utf8)
  }
  return dir.path
}

@Test func theBranchIsFoundFromAnyFolderInsideTheRepo() throws {
  let root = try makeDir([".git/HEAD": "ref: refs/heads/dev\n", "src/a/b.txt": ""])
  #expect(GitHead.branch(inFolder: root, home: root) == "dev")
  #expect(GitHead.branch(inFolder: root + "/src/a", home: root) == "dev")
}

@Test func aFolderOutsideAnyRepoHasNoBranch() throws {
  let root = try makeDir(["src/a.txt": ""])
  #expect(GitHead.branch(inFolder: root + "/src", home: root) == nil)
}

@Test func aWorktreeOrSubmoduleFollowsItsGitdirPointer() throws {
  let real = try makeDir(["wt/HEAD": "ref: refs/heads/wt-branch\n"])
  let absolute = try makeDir([".git": "gitdir: \(real)/wt\n"])
  #expect(GitHead.branch(inFolder: absolute, home: absolute) == "wt-branch")
  let relative = try makeDir([".git": "gitdir: ../\(URL(fileURLWithPath: real).lastPathComponent)/wt\n"])
  #expect(GitHead.branch(inFolder: relative, home: relative) == "wt-branch")
}

@Test func anUnreadableHeadOrPointerHasNoBranch() throws {
  let noHead = try makeDir([".git/config": ""])
  #expect(GitHead.branch(inFolder: noHead, home: noHead) == nil)
  let badPointer = try makeDir([".git": "not a pointer\n"])
  #expect(GitHead.branch(inFolder: badPointer, home: badPointer) == nil)
  let danglingPointer = try makeDir([".git": "gitdir: /definitely/not/here\n"])
  #expect(GitHead.branch(inFolder: danglingPointer, home: danglingPointer) == nil)
}
