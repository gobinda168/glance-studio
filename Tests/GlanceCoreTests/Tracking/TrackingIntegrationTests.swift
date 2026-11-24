import Foundation
import Testing
@testable import GlanceCore

/// A scratch repository with one commit, and a second worktree beside it.
private struct Scratch {
  let base = FileManager.default.temporaryDirectory.appendingPathComponent("track-\(UUID().uuidString)")
  var main: String { base.appendingPathComponent("app").path }
  var other: String { base.appendingPathComponent("app-fix").path }

  init() throws {
    try FileManager.default.createDirectory(atPath: base.appendingPathComponent("app").path,
                                            withIntermediateDirectories: true)
    try git(main, "init", "-q", "-b", "main")
    try write("README.md", "hello\n", in: main)
    try git(main, "add", ".")
    try git(main, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "first")
    try git(main, "worktree", "add", "-q", "-b", "fix", other)
  }

  func write(_ path: String, _ text: String, in root: String) throws {
    try text.write(toFile: root + "/" + path, atomically: true, encoding: .utf8)
  }

  @discardableResult
  func git(_ root: String, _ arguments: String...) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    process.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  }
}

private func hook(_ event: String, _ session: String, cwd: String, id: String? = nil) -> HookInput {
  HookInput(sessionID: session, cwd: cwd, event: event, toolName: id == nil ? nil : "Bash", toolUseID: id)
}

struct TrackingIntegrationTests {
  @Test func twoSessionsAHandEditAndACommitInRealWorktrees() throws {
    let repo = try Scratch()
    defer { try? FileManager.default.removeItem(at: repo.base) }
    let ledger = Ledger(folder: repo.base.appendingPathComponent("ledger"))
    let track = ChangeTracker(ledger: ledger, alive: { _ in true })
    _ = track.handle(hook("SessionStart", "s1", cwd: repo.main))
    _ = track.handle(hook("SessionStart", "s2", cwd: repo.other))
    _ = track.handle(hook("PreToolUse", "s1", cwd: repo.main, id: "a"))
    try repo.write("one.txt", "1\n", in: repo.main)
    _ = track.handle(hook("PostToolUse", "s1", cwd: repo.main, id: "a"))
    _ = track.handle(hook("PreToolUse", "s2", cwd: repo.other, id: "b"))
    try repo.write("two.txt", "2\n", in: repo.other)
    _ = track.handle(hook("PostToolUse", "s2", cwd: repo.other, id: "b"))
    try repo.write("README.md", "edited by hand\n", in: repo.main)
    _ = track.handle(hook("PreToolUse", "s1", cwd: repo.main, id: "c")) // sees the hand edit
    try repo.git(repo.main, "add", "one.txt")
    try repo.git(repo.main, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "one")
    _ = track.handle(hook("PostToolUse", "s1", cwd: repo.main, id: "c"))

    let common = try #require(RepoLocation.find(cwd: repo.main)).commonDir
    let state = ledger.state(repo: common)
    let mainTree = try #require(RepoLocation.find(cwd: repo.main)).worktree
    let otherTree = try #require(RepoLocation.find(cwd: repo.other)).worktree
    let mainFiles = Uncommitted.attribute(state.fingerprints[mainTree] ?? Fingerprint(),
                                          authors: state.authors[mainTree] ?? [:])
    #expect(mainFiles.map(\.path) == ["README.md"]) // one.txt was committed
    #expect(mainFiles.first?.author == .outside)
    let otherFiles = Uncommitted.attribute(state.fingerprints[otherTree] ?? Fingerprint(),
                                           authors: state.authors[otherTree] ?? [:])
    #expect(otherFiles.map(\.author) == [.session("s2")])
  }

  @Test func stagingAndTouchingDontTakeAFileFromItsAuthor() throws {
    let repo = try Scratch()
    defer { try? FileManager.default.removeItem(at: repo.base) }
    let ledger = Ledger(folder: repo.base.appendingPathComponent("ledger"))
    let track = ChangeTracker(ledger: ledger, alive: { _ in true })
    _ = track.handle(hook("PreToolUse", "a", cwd: repo.main, id: "1"))
    try repo.write("README.md", "edited by a\n", in: repo.main)
    _ = track.handle(hook("PostToolUse", "a", cwd: repo.main, id: "1"))
    try repo.git(repo.main, "add", "README.md") // the user stages it
    _ = track.handle(hook("PreToolUse", "b", cwd: repo.main, id: "2"))
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                          ofItemAtPath: repo.main + "/README.md") // session b touches it
    _ = track.handle(hook("PostToolUse", "b", cwd: repo.main, id: "2"))

    let place = try #require(RepoLocation.find(cwd: repo.main))
    let state = ledger.state(repo: place.commonDir)
    let files = Uncommitted.attribute(state.fingerprints[place.worktree] ?? Fingerprint(),
                                      authors: state.authors[place.worktree] ?? [:])
    #expect(files.map(\.path) == ["README.md"])
    #expect(files.first?.status == "M.")
    #expect(files.first?.author == .session("a"))
    #expect(ledger.records(repo: place.commonDir).map(\.kind) == [.change])
  }

  @Test func parallelToolCallsAllCloseTheirCalls() throws {
    let repo = try Scratch()
    defer { try? FileManager.default.removeItem(at: repo.base) }
    for index in 0..<300 { try repo.write("f\(index).txt", "\(index)\n", in: repo.main) }
    let ledger = Ledger(folder: repo.base.appendingPathComponent("ledger"))
    // One tracker per hook, as each hook is its own process.
    _ = ChangeTracker(ledger: ledger, alive: { _ in true }).handle(hook("SessionStart", "s1", cwd: repo.main))
    DispatchQueue.concurrentPerform(iterations: 6) { index in
      _ = ChangeTracker(ledger: ledger, alive: { _ in true })
        .handle(hook("PreToolUse", "s1", cwd: repo.main, id: "p\(index)"))
    }
    let common = try #require(RepoLocation.find(cwd: repo.main)).commonDir
    #expect(ledger.state(repo: common).open.count == 6)
    DispatchQueue.concurrentPerform(iterations: 6) { index in
      _ = ChangeTracker(ledger: ledger, alive: { _ in true })
        .handle(hook("PostToolUse", "s1", cwd: repo.main, id: "p\(index)"))
    }
    #expect(ledger.state(repo: common).open.isEmpty)
  }

  @Test func aHookStaysWithinBudgetOnFiveHundredDirtyFiles() throws {
    let repo = try Scratch()
    defer { try? FileManager.default.removeItem(at: repo.base) }
    for index in 0..<500 { try repo.write("f\(index).txt", "\(index)\n", in: repo.main) }
    let ledger = Ledger(folder: repo.base.appendingPathComponent("ledger"))
    let track = ChangeTracker(ledger: ledger, alive: { _ in true })
    _ = track.handle(hook("PreToolUse", "s1", cwd: repo.main, id: "warm")) // first fingerprint reads every file
    _ = track.handle(hook("PostToolUse", "s1", cwd: repo.main, id: "warm"))
    let start = Date()
    for index in 0..<10 {
      _ = track.handle(hook("PreToolUse", "s1", cwd: repo.main, id: "t\(index)"))
      _ = track.handle(hook("PostToolUse", "s1", cwd: repo.main, id: "t\(index)"))
    }
    let perHook = Date().timeIntervalSince(start) / 20
    #expect(perHook < 0.030, "per hook: \(perHook * 1000) ms")
  }
}
