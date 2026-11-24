import Foundation
import Testing
@testable import GlanceCore

private func makeTree(_ files: [String: String]) throws -> String {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glance-location-\(UUID().uuidString)")
  for (path, content) in files {
    let url = dir.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: url, atomically: true, encoding: .utf8)
  }
  return dir.path
}

private let noHome = "/nonexistent-home"

@Test func theMainCheckoutIsNamedByItsRootFolderEvenFromASubfolder() throws {
  let dir = try makeTree(["acme/.git/HEAD": "ref: refs/heads/main\n", "acme/Sources/App/a.swift": ""])
  let location = TabLocation.read(folder: dir + "/acme/Sources/App", home: noHome)
  #expect(location?.folder == "acme")
  #expect(location?.head == .branch("main"))
  #expect(location?.repository == nil)
  #expect(location?.isLinkedWorktree == false)
}

@Test func aLinkedWorktreeIsNamedByItsOwnFolderAndKnowsItsRepository() throws {
  let dir = try makeTree(["acme/.git/worktrees/rotate/HEAD": "ref: refs/heads/priya/rotate-refresh\n"])
  try "gitdir: \(dir)/acme/.git/worktrees/rotate\n".write(toFile: try makeFile(dir, "acme-worktrees/rotate-refresh/.git"),
                                                          atomically: true, encoding: .utf8)
  let location = TabLocation.read(folder: dir + "/acme-worktrees/rotate-refresh", home: noHome)
  #expect(location?.folder == "rotate-refresh")
  #expect(location?.head == .branch("priya/rotate-refresh"))
  #expect(location?.repository == "acme")
  #expect(location?.isLinkedWorktree == true)
}

@Test func aRelativeGitdirStillFindsTheRepository() throws {
  let dir = try makeTree(["acme/.git/worktrees/x/HEAD": "ref: refs/heads/x\n",
                          "wt/x/.git": "gitdir: ../../acme/.git/worktrees/x\n"])
  #expect(TabLocation.read(folder: dir + "/wt/x", home: noHome)?.repository == "acme")
}

@Test func aSubmoduleIsNotAWorktree() throws {
  let dir = try makeTree(["acme/.git/modules/lib/HEAD": "ref: refs/heads/main\n", "acme/lib/.git": "gitdir: ../.git/modules/lib\n"])
  let location = TabLocation.read(folder: dir + "/acme/lib", home: noHome)
  #expect(location?.folder == "lib")
  #expect(location?.isLinkedWorktree == false)
}

@Test func aDetachedHeadSaysSo() throws {
  let dir = try makeTree(["acme/.git/HEAD": "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678\n"])
  let location = TabLocation.read(folder: dir + "/acme", home: noHome)
  #expect(location?.head == .detached("a1b2c3d"))
  #expect(location?.head.label == "detached a1b2c3d")
  #expect(TabLocation.Head.branch("main").label == "main")
}

@Test func outsideARepoThereIsNoLocation() throws {
  let dir = try makeTree(["plain/a.txt": ""])
  #expect(TabLocation.read(folder: dir + "/plain", home: dir) == nil)
}

@Test func aRealGitWorktreeIsRecognised() throws {
  let dir = try makeTree(["acme/a.txt": "a\n"])
  let repo = dir + "/acme"
  func git(_ arguments: String...) { _ = GitRun.data(repo, ["-c", "user.name=t", "-c", "user.email=t@t"] + arguments) }
  git("init", "-q", "-b", "main")
  git("add", ".")
  git("commit", "-qm", "first")
  git("worktree", "add", "-q", dir + "/wt/feature", "-b", "feat/x")
  #expect(TabLocation.read(folder: repo, home: noHome)?.isLinkedWorktree == false)
  let linked = TabLocation.read(folder: dir + "/wt/feature", home: noHome)
  #expect(linked?.folder == "feature")
  #expect(linked?.repository == "acme")
  #expect(linked?.head == .branch("feat/x"))
}

@Test func theLocationReadsAsASentence() {
  let main = TabLocation.Location(folder: "acme", path: "~/Code/acme", repository: nil, head: .branch("main"))
  #expect(main.sentence(base: "main") == "Main checkout at ~/Code/acme, on main, the base branch")
  #expect(main.sentence(base: nil) == "Main checkout at ~/Code/acme, on main")
  let linked = TabLocation.Location(folder: "rotate", path: "~/wt/rotate", repository: "acme", head: .branch("priya/x"))
  #expect(linked.sentence(base: "main") == "Worktree of acme at ~/wt/rotate, on priya/x, against main")
  let detached = TabLocation.Location(folder: "acme", path: "~/Code/acme", repository: nil, head: .detached("a1b2c3d"))
  #expect(detached.sentence(base: "main") == "Main checkout at ~/Code/acme, detached at a1b2c3d")
}

@Test func thePathIsShortenedUnderHome() throws {
  let dir = try makeTree(["Code/acme/.git/HEAD": "ref: refs/heads/main\n"])
  #expect(TabLocation.read(folder: dir + "/Code/acme", home: dir)?.path == "~/Code/acme")
}

private func makeFile(_ dir: String, _ path: String) throws -> String {
  let url = URL(fileURLWithPath: dir).appendingPathComponent(path)
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  return url.path
}
