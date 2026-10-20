import Foundation
import Testing
@testable import GlanceCore

/// A scratch repository with three committed files; hooks and signing off, whatever the user's git config says.
private func scratchRepository() throws -> String {
  let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("glance-fix-test-\(UUID().uuidString)")
  try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
  git(root, "init", "-q")
  git(root, "config", "user.email", "test@example.com")
  git(root, "config", "user.name", "Test")
  git(root, "config", "commit.gpgsign", "false")
  git(root, "config", "core.hooksPath", "/dev/null")
  try write(root, "keep.txt", "one\ntwo\nthree\n")
  try write(root, "mine.txt", "mine\n")
  try write(root, "old.txt", "old\n")
  git(root, "add", "-A")
  git(root, "commit", "-q", "-m", "base")
  return root
}

@discardableResult private func git(_ root: String, _ arguments: String...) -> String {
  String(decoding: GitHubCLI.execute("/usr/bin/git", ["-C", root] + arguments)?.output ?? Data(), as: UTF8.self)
}

private func write(_ root: String, _ path: String, _ text: String) throws {
  try text.write(toFile: (root as NSString).appendingPathComponent(path), atomically: true, encoding: .utf8)
}

private func read(_ root: String, _ path: String) -> String? {
  try? String(contentsOfFile: (root as NSString).appendingPathComponent(path), encoding: .utf8)
}

private func remove(_ root: String, _ path: String) throws {
  try FileManager.default.removeItem(atPath: (root as NSString).appendingPathComponent(path))
}

/// Claude's work in the scratch repository: one file changed, one added, one deleted.
private func claudeEdits(_ root: String) throws {
  try write(root, "keep.txt", "one\nTWO\nthree\n")
  try write(root, "new.txt", "new\n")
  try remove(root, "old.txt")
}

@Test func aSnapshotSeesEveryFileAndChangesNothing() throws {
  let root = try scratchRepository()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try write(root, "mine.txt", "mine, edited\n")
  try write(root, "untracked.txt", "new\n")
  let first = try FixPatch.snapshot(root: root).get()
  #expect(first.count == 40)
  #expect(try FixPatch.snapshot(root: root).get() == first)
  #expect(git(root, "diff", "--cached", "--name-only").isEmpty) // the real index is untouched
  #expect(git(root, "status", "--porcelain").contains("?? untracked.txt"))
}

@Test func aFixIsWhatChangedSinceTheSnapshotAndNotTheUsersEdits() throws {
  let root = try scratchRepository()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try write(root, "mine.txt", "mine, edited\n") // the user's own edit, before the fix
  let before = try FixPatch.snapshot(root: root).get()
  #expect(try FixPatch.collect(root: root, before: before).get() == nil)
  try claudeEdits(root)
  let fix = try #require(try FixPatch.collect(root: root, before: before).get())
  #expect(fix.changes == [.init(path: "keep.txt", kind: .modified), .init(path: "new.txt", kind: .added),
                          .init(path: "old.txt", kind: .deleted)])
  #expect(fix.patch.map(\.path) == ["keep.txt", "new.txt", "old.txt"])
  #expect(fix.overlap.isEmpty)
}

@Test func aFixOnAFileHoldingTheUsersEditsSaysSo() throws {
  let root = try scratchRepository()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try write(root, "keep.txt", "one\ntwo, mine\nthree\n")
  let before = try FixPatch.snapshot(root: root).get()
  try write(root, "keep.txt", "ONE\ntwo, mine\nthree\n")
  let fix = try #require(try FixPatch.collect(root: root, before: before).get())
  #expect(fix.overlap == ["keep.txt"])
}

@Test func acceptingCommitsOnlyTheFixsFiles() throws {
  let root = try scratchRepository()
  defer { try? FileManager.default.removeItem(atPath: root) }
  // The user's own work from before the fix: an edit, and a new file staged.
  try write(root, "mine.txt", "mine, edited\n")
  try write(root, "staged.txt", "staged\n")
  git(root, "add", "staged.txt")
  let before = try FixPatch.snapshot(root: root).get()
  try claudeEdits(root)
  let fix = try #require(try FixPatch.collect(root: root, before: before).get())
  let sha = try FixPatch.commit(fix, message: "Address review: x", root: root).get()
  #expect(sha.count >= 7)
  #expect(git(root, "show", "--name-only", "--format=", "HEAD").split(separator: "\n").sorted()
    == ["keep.txt", "new.txt", "old.txt"])
  #expect(git(root, "log", "-1", "--format=%s") == "Address review: x\n")
  #expect(git(root, "status", "--porcelain").contains(" M mine.txt")) // still the user's, uncommitted
  #expect(git(root, "diff", "--cached", "--name-only") == "staged.txt\n") // still staged, not committed
}

@Test func rejectingPutsBackOnlyWhatTheFixChanged() throws {
  let root = try scratchRepository()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try write(root, "mine.txt", "mine, edited\n")
  let before = try FixPatch.snapshot(root: root).get()
  try claudeEdits(root)
  let fix = try #require(try FixPatch.collect(root: root, before: before).get())
  #expect(try FixPatch.revert(fix, root: root).get().isEmpty)
  #expect(read(root, "keep.txt") == "one\ntwo\nthree\n")
  #expect(read(root, "old.txt") == "old\n")
  #expect(read(root, "new.txt") == nil)
  #expect(read(root, "mine.txt") == "mine, edited\n")
  #expect(git(root, "diff", "--cached", "--name-only").isEmpty)
}

@Test func rejectingKeepsAFileChangedAgainAfterTheFix() throws {
  let root = try scratchRepository()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let before = try FixPatch.snapshot(root: root).get()
  try claudeEdits(root)
  let fix = try #require(try FixPatch.collect(root: root, before: before).get())
  try write(root, "new.txt", "new, then mine\n")
  #expect(try FixPatch.revert(fix, root: root).get() == ["new.txt"])
  #expect(read(root, "new.txt") == "new, then mine\n")
  #expect(read(root, "keep.txt") == "one\ntwo\nthree\n")
}

@Test func pushingWithoutARemoteFails() throws {
  let root = try scratchRepository()
  defer { try? FileManager.default.removeItem(atPath: root) }
  #expect((try? FixPatch.push(root: root).get()) == nil)
}
