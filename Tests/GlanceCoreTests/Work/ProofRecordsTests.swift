import Foundation
import Testing
@testable import GlanceCore

@Suite struct ProofRecordsTests {
  func record(_ session: String, branch: String?, updated: Double, worktree: String? = "/w", cwd: String? = nil) -> WorkRecord {
    var r = WorkRecord(session: session, updated: Date(timeIntervalSince1970: updated))
    r.branch = branch; r.worktree = worktree; r.cwd = cwd
    return r
  }

  @Test func keepsOnlyTheBranchsRecordsOfThisRepositoryNewestFirst() {
    let records = [
      record("old", branch: "feat/x", updated: 100),
      record("other-branch", branch: "feat/y", updated: 300),
      record("elsewhere", branch: "feat/x", updated: 400),
      record("new", branch: "feat/x", updated: 200),
      record("no-branch", branch: nil, updated: 500),
    ]
    let found = ProofRecords.match(records, branch: "feat/x", commonDir: "/repo/.git") { r in
      r.session == "elsewhere" ? .commonDir("/other/.git") : .commonDir("/repo/.git")
    }
    #expect(found.map(\.session) == ["new", "old"])
  }

  @Test func resolvesOnlyTheRecordsOfTheBranch() {
    let records = (0..<20).map { record("s\($0)", branch: $0 == 3 ? "feat/x" : "other", updated: Double($0)) }
    var resolved: [String] = []
    let found = ProofRecords.match(records, branch: "feat/x", commonDir: "/repo/.git") { r in
      resolved.append(r.session)
      return .commonDir("/repo/.git")
    }
    #expect(found.map(\.session) == ["s3"])
    #expect(resolved == ["s3"])
  }

  @Test func anOldRecordWhoseFoldersAreGoneStillMatchesItsBranch() {
    let records = [record("gone", branch: "feat/x", updated: 100), record("unknown", branch: "feat/x", updated: 200)]
    let found = ProofRecords.match(records, branch: "feat/x", commonDir: "/repo/.git") { r in
      r.session == "gone" ? .gone : .unknown
    }
    // A folder that exists but can't be placed in a repository is not this one's; a removed worktree is kept.
    #expect(found.map(\.session) == ["gone"])
  }

  @Test func anOldGoneRecordOfASharedBranchNameDoesNotMatch() {
    for name in ["main", "master", "develop", "trunk"] {
      let found = ProofRecords.match([record("gone", branch: name, updated: 100)], branch: name, commonDir: "/repo/.git") { _ in .gone }
      #expect(found.isEmpty)
    }
  }

  @Test func aRecordThatStoredItsRepositoryIsComparedWithoutGit() {
    var mine = record("mine", branch: "main", updated: 100); mine.commonDir = "/repo/.git"
    var theirs = record("theirs", branch: "main", updated: 200); theirs.commonDir = "/other/.git"
    var resolved = 0
    let found = ProofRecords.match([mine, theirs], branch: "main", commonDir: "/repo/.git") { _ in resolved += 1; return .gone }
    // Even a shared branch name on a removed worktree matches, because the repository is known.
    #expect(found.map(\.session) == ["mine"])
    #expect(resolved == 0)
  }

  @Test func theRepositoryIsComparedWithSymlinksResolved() throws {
    let real = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")
    let link = FileManager.default.temporaryDirectory.appendingPathComponent("rec-link-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: real.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    var stored = record("a", branch: "x", updated: 1); stored.commonDir = link.path + "/.git/"
    let viaLink = ProofRecords.match([stored], branch: "x", commonDir: real.path + "/.git") { _ in .unknown }
    #expect(viaLink.count == 1)
    var plain = record("b", branch: "x", updated: 1); plain.commonDir = real.path + "/.git"
    #expect(ProofRecords.match([plain], branch: "x", commonDir: link.path + "/.git") { _ in .unknown }.count == 1)
    // An old record placed by git reports a path that may be spelt the other way too.
    let old = record("c", branch: "x", updated: 1)
    #expect(ProofRecords.match([old], branch: "x", commonDir: link.path + "/.git") { _ in .commonDir(real.path + "/.git") }.count == 1)
  }

  @Test func equalTimesKeepAStableOrder() {
    let records = [record("b", branch: "x", updated: 100), record("a", branch: "x", updated: 100)]
    let found = ProofRecords.match(records, branch: "x", commonDir: "/c") { _ in .commonDir("/c") }
    #expect(found.map(\.session) == ["a", "b"])
  }

  @Test func theCommonDirIsComparedWithoutATrailingSlash() {
    let records = [record("a", branch: "x", updated: 1)]
    let found = ProofRecords.match(records, branch: "x", commonDir: "/repo/.git/") { _ in .commonDir("/repo/.git") }
    #expect(found.count == 1)
  }

  @Test func noMatchIsEmpty() {
    #expect(ProofRecords.match([], branch: "x", commonDir: "/c") { _ in .gone }.isEmpty)
    #expect(ProofRecords.match([record("a", branch: "y", updated: 1)], branch: "x", commonDir: "/c") { _ in .gone }.isEmpty)
    #expect(ProofRecords.match([record("a", branch: "", updated: 1)], branch: "", commonDir: "/c") { _ in .gone }.isEmpty)
  }

  // MARK: Home

  @Test func homeIsGoneWhenEveryFolderIsMissing() {
    let r = record("a", branch: "x", updated: 1, worktree: "/definitely/not/here/wt", cwd: "/definitely/not/here")
    #expect(ProofRecords.home(of: r) == .gone)
  }

  @Test func homeIsUnknownWithoutAnyFolder() {
    #expect(ProofRecords.home(of: record("a", branch: "x", updated: 1, worktree: nil, cwd: nil)) == .unknown)
  }

  @Test func homeFallsBackToTheCwdWhenTheWorktreeIsGone() {
    let dir = NSTemporaryDirectory()
    let r = record("a", branch: "x", updated: 1, worktree: "/definitely/not/here/wt", cwd: dir)
    var asked: [String] = []
    let home = ProofRecords.home(of: r) { folder in asked.append(folder); return "/repo/.git" }
    #expect(home == .commonDir("/repo/.git"))
    #expect(asked == [dir])
  }

  @Test func homeIsUnknownWhenGitCannotPlaceAnExistingFolder() {
    let r = record("a", branch: "x", updated: 1, worktree: NSTemporaryDirectory(), cwd: nil)
    #expect(ProofRecords.home(of: r) { _ in nil } == .unknown)
  }

  // MARK: Placing a record

  @Test func placeFollowsTheLatestBranchAndItsRepository() {
    var r = WorkRecord(session: "s", updated: Date())
    r.place(cwd: "/a", worktree: "/a", branch: "feat/x", commonDir: "/repo/.git")
    r.place(cwd: "/b", worktree: "/b", branch: "feat/y", commonDir: "/other/.git")
    #expect(r.cwd == "/a" && r.worktree == "/a")
    #expect(r.branch == "feat/y" && r.commonDir == "/other/.git")
    r.place(cwd: nil, worktree: nil, branch: nil, commonDir: nil)
    #expect(r.branch == "feat/y" && r.commonDir == "/other/.git")
  }

  @Test func aRecordWrittenBeforeCommonDirStillOpens() throws {
    let json = #"{"session":"s1","branch":"feat/x","updated":"2026-11-01T10:00:00Z"}"#
    let r = try WorkRecord.decoder.decode(WorkRecord.self, from: Data(json.utf8))
    #expect(r.branch == "feat/x" && r.commonDir == nil)
  }
}

@Suite struct GitCommonDirTests {
  func scratch() throws -> URL {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("gcd-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base.appendingPathComponent("repo/.git/worktrees/wt"), withIntermediateDirectories: true)
    return base
  }

  @Test func aMainWorktreeIsItsOwnGitFolder() throws {
    let base = try scratch()
    let found = try #require(GitCommonDir.of(root: base.appendingPathComponent("repo")))
    #expect(found.linked == false && found.commonDir.path == base.appendingPathComponent("repo/.git").standardizedFileURL.path)
  }

  @Test func aLinkedWorktreeFollowsGitdirAndCommondir() throws {
    let base = try scratch()
    try "../..\n".write(to: base.appendingPathComponent("repo/.git/worktrees/wt/commondir"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: base.appendingPathComponent("wt"), withIntermediateDirectories: true)
    // A relative gitdir, as `git worktree add --relative-paths` writes it.
    try "gitdir: ../repo/.git/worktrees/wt\n".write(to: base.appendingPathComponent("wt/.git"), atomically: true, encoding: .utf8)
    let found = try #require(GitCommonDir.of(root: base.appendingPathComponent("wt")))
    #expect(found.linked)
    #expect(GitCommonDir.normalize(found.commonDir.path) == GitCommonDir.normalize(base.appendingPathComponent("repo/.git").path))
    #expect(GitCommonDir.find(from: base.appendingPathComponent("wt").path, home: "/nonexistent")
            == GitCommonDir.normalize(base.appendingPathComponent("repo/.git").path))
  }

  @Test func nothingReadableIsNil() throws {
    let base = try scratch()
    try "gitdir: ../repo/.git/worktrees/wt\n".write(to: base.appendingPathComponent("repo/wt.git"), atomically: true, encoding: .utf8)
    #expect(GitCommonDir.of(root: base.appendingPathComponent("nowhere")) == nil)
    // A gitdir that isn't there.
    try FileManager.default.createDirectory(at: base.appendingPathComponent("wt2"), withIntermediateDirectories: true)
    try "gitdir: ../repo/.git/worktrees/missing\n".write(to: base.appendingPathComponent("wt2/.git"), atomically: true, encoding: .utf8)
    #expect(GitCommonDir.of(root: base.appendingPathComponent("wt2")) == nil)
  }

  @Test func aSubmodulesGitdirIsItsOwnCommonDirectory() throws {
    let base = try scratch()
    let modules = base.appendingPathComponent("repo/.git/modules/lib")
    try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
    let sub = base.appendingPathComponent("repo/lib")
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    try "gitdir: ../.git/modules/lib\n".write(to: sub.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
    let found = try #require(GitCommonDir.of(root: sub))
    #expect(GitCommonDir.normalize(found.commonDir.path) == GitCommonDir.normalize(modules.path))
  }
}

@Suite struct UncommittedChangesTests {
  func git(_ folder: URL, _ arguments: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", folder.path, "-c", "user.name=t", "-c", "user.email=t@example.com"] + arguments
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try p.run(); p.waitUntilExit()
  }
  func repo() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("unc-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try git(dir, ["init", "-q"])
    try "a".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try git(dir, ["add", "a.txt"])
    try git(dir, ["commit", "-q", "-m", "first"])
    return dir
  }

  @Test func aCleanRepositoryHasNoChanges() throws {
    #expect(ProofRecords.hasUncommittedChanges(inFolder: try repo().path) == false)
  }

  @Test func editedAndUntrackedFilesCount() throws {
    let edited = try repo()
    try "b".write(to: edited.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    #expect(ProofRecords.hasUncommittedChanges(inFolder: edited.path) == true)
    let untracked = try repo()
    try "c".write(to: untracked.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
    #expect(ProofRecords.hasUncommittedChanges(inFolder: untracked.path) == true)
  }

  @Test func whatGitCantReadIsNilNotClean() throws {
    let plain = FileManager.default.temporaryDirectory.appendingPathComponent("unc-plain-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
    #expect(ProofRecords.hasUncommittedChanges(inFolder: plain.path) == nil)
    #expect(ProofRecords.hasUncommittedChanges(inFolder: plain.path + "/missing") == nil)
  }

  @Test func gitThatTakesTooLongIsTerminated() throws {
    let dir = try repo()
    let start = Date()
    // An alias that sleeps stands in for a hung git (its output is discarded so only git holds the pipe).
    let result = GitRun.data(dir.path, ["-c", "alias.nap=!sleep 20 >/dev/null", "nap"], timeout: 0.5)
    #expect(result == nil)
    #expect(Date().timeIntervalSince(start) < 10)
  }
}
