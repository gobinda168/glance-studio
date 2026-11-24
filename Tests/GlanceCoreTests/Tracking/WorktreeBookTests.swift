import Foundation
import Testing
@testable import GlanceCore

@discardableResult
private func git(_ root: String, _ arguments: String...) throws -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
  process.arguments = ["-C", root, "-c", "user.email=t@t", "-c", "user.name=t", "-c", "protocol.file.allow=always"]
    + arguments
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = FileHandle.nullDevice
  try process.run()
  process.waitUntilExit()
  return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}

/// A repository at `base/<name>` with one commit.
private func makeRepo(_ base: URL, _ name: String) throws -> String {
  let root = base.appendingPathComponent(name).path
  try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
  try git(root, "init", "-q", "-b", "main")
  try "\(name)\n".write(toFile: root + "/README.md", atomically: true, encoding: .utf8)
  try git(root, "add", ".")
  try git(root, "commit", "-qm", "first")
  return root
}

struct WorktreeBookTests {
  @Test func parsesWorktreeListPorcelain() {
    let out = """
    worktree /r/app
    HEAD 1111111111111111111111111111111111111111
    branch refs/heads/main

    worktree /r/app-fix
    HEAD 2222222222222222222222222222222222222222
    branch refs/heads/fix/x

    worktree /r/app-detached
    HEAD 3333333333333333333333333333333333333333
    detached

    """
    let listed = WorktreeBook.parseList(out)
    #expect(listed.map(\.path) == ["/r/app", "/r/app-fix", "/r/app-detached"])
    #expect(listed.map(\.branch) == ["main", "fix/x", nil])
    #expect(listed.map(\.isMain) == [true, false, false])
  }

  @Test func loadListsEachRepositorysOwnWorktrees() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("book-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    let app = try makeRepo(base, "app")
    try git(app, "worktree", "add", "-q", "-b", "fix", base.appendingPathComponent("app-fix").path)
    // A submodule: its common git folder sits inside the superproject's .git, whose parent folder is another repo.
    let library = try makeRepo(base, "library")
    try git(app, "submodule", "add", "-q", library, "vendor/library")
    let ledger = Ledger(folder: base.appendingPathComponent("ledger"))
    let appPlace = try #require(RepoLocation.find(cwd: app))
    let submodule = try #require(RepoLocation.find(cwd: app + "/vendor/library"))
    ledger.save(TrackState(repo: appPlace.commonDir))
    ledger.save(TrackState(repo: submodule.commonDir))

    let trees = WorktreeBook.load(ledger: ledger, alive: { _ in false })
    let appTree = try #require(trees.first { $0.repo == appPlace.commonDir })
    #expect(appTree.main == appPlace.worktree)
    #expect(appTree.worktrees.map(\.branch) == ["main", "fix"])
    // The submodule's listing is the submodule's, not the superproject's.
    let subTree = try #require(trees.first { $0.repo == submodule.commonDir })
    #expect(!subTree.worktrees.contains { $0.path == appPlace.worktree })
  }

  @Test func aSessionInARemovedWorktreeIsAnOrphanNotLost() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("book-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    let app = try makeRepo(base, "app")
    let gone = base.appendingPathComponent("app-gone").path
    try git(app, "worktree", "add", "-q", "-b", "gone", gone)
    try git(app, "worktree", "remove", "--force", gone)
    try git(app, "branch", "-D", "gone")
    let place = try #require(RepoLocation.find(cwd: app))
    var state = TrackState(repo: place.commonDir)
    let there = TrackedSession(id: "kept", worktree: place.worktree, branch: "main", pid: nil, terminal: nil, task: nil,
                               started: Date(timeIntervalSince1970: 1), ended: Date(timeIntervalSince1970: 2))
    let removed = TrackedSession(id: "old", worktree: gone, branch: "gone", pid: nil, terminal: nil, task: "done",
                                 started: Date(timeIntervalSince1970: 3), ended: Date(timeIntervalSince1970: 4))
    state.sessions = ["kept": there, "old": removed]
    let ledger = Ledger(folder: base.appendingPathComponent("ledger"))
    ledger.save(state)

    let tree = try #require(WorktreeBook.load(ledger: ledger, alive: { _ in false }).first { $0.repo == place.commonDir })
    #expect(tree.orphans.map(\.id) == ["old"])
    #expect(tree.worktrees.flatMap(\.sessions).map(\.id) == ["kept"])
  }

  @Test func aWorktreeWarnsWhenItMixesAuthorsOrSessions() {
    let mine = AttributedFile(path: "a", status: ".M", author: .session("s1"))
    let hand = AttributedFile(path: "b", status: ".M", author: .outside)
    #expect(!WorktreeBook.warning(files: [mine], live: 1))
    #expect(WorktreeBook.warning(files: [mine, hand], live: 1))
    #expect(WorktreeBook.warning(files: [], live: 2))
  }

  @Test func sumsNumstatLines() {
    #expect(WorktreeBook.numstat("3\t1\ta.swift\n-\t-\timage.png\n10\t0\tb.md\n") == (13, 1))
    #expect(WorktreeBook.numstat("") == (0, 0))
  }

  private func removable(isMain: Bool = false, statusRead: Bool = true, tooMany: Bool = false, files: Int = 0,
                         live: Int = 0, merged: Bool = true) -> Bool {
    WorktreeBook.removable(isMain: isMain, statusRead: statusRead, tooMany: tooMany, files: files, live: live) { merged }
  }

  @Test func onlyACleanIdleMergedWorktreeCanBeRemoved() {
    #expect(removable())
    #expect(!removable(live: 1))
    #expect(!removable(statusRead: false))
    #expect(!removable(tooMany: true))
    #expect(!removable(isMain: true))
    #expect(!removable(files: 1))
    #expect(!removable(merged: false))
  }

  @Test func removableChecksTheMergeLast() {
    var asked = false
    let result = WorktreeBook.removable(isMain: false, statusRead: true, tooMany: false, files: 0, live: 1) {
      asked = true
      return true
    }
    #expect(!result)
    #expect(!asked)
  }
}
