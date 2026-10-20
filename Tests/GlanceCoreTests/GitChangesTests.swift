import Foundation
import Testing
@testable import GlanceCore

@Test func readsEveryStatusFromPorcelainOutput() {
  let output = " M Sources/a b.swift\0A  new.txt\0 D gone.md\0?? notes/todo.txt\0R  moved.swift\0old.swift\0MM both.swift\0!! ignored\0"
  #expect(GitChanges.parse(output) == [
    .init(path: "Sources/a b.swift", status: .modified),
    .init(path: "both.swift", status: .modified),
    .init(path: "gone.md", status: .deleted),
    .init(path: "moved.swift", status: .renamed, oldPath: "old.swift"),
    .init(path: "new.txt", status: .added),
    .init(path: "notes/todo.txt", status: .untracked),
  ])
  #expect(GitChanges.parse("") == [])
}

@Test func keepsOnlyTheRootsFolderWhenTheRootIsASubfolder() {
  let changes: [GitChanges.Change] = [.init(path: "app/src/a.ts", status: .modified), .init(path: "docs/b.md", status: .added),
                                      .init(path: "app/c.ts", status: .renamed, oldPath: "app/old.ts")]
  #expect(GitChanges.relative(changes, prefix: "app/") == [.init(path: "src/a.ts", status: .modified),
                                                          .init(path: "c.ts", status: .renamed, oldPath: "old.ts")])
  #expect(GitChanges.relative(changes, prefix: "") == changes)
}

private func git(_ dir: URL, _ args: String...) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
  process.arguments = ["-C", dir.path, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  try process.run()
  process.waitUntilExit()
}

@Test func listsARealRepositorysChangesAndHeadText() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  try git(dir, "init", "-q")
  try "one\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
  try "keep\n".write(to: dir.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
  try git(dir, "add", ".")
  try git(dir, "commit", "-q", "-m", "first")
  try "two\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
  try "new\n".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
  try FileManager.default.removeItem(at: dir.appendingPathComponent("c.txt"))

  #expect(GitChanges.status(root: dir.path) == [
    .init(path: "a.txt", status: .modified), .init(path: "b.txt", status: .untracked), .init(path: "c.txt", status: .deleted),
  ])
  #expect(GitChanges.headText(root: dir.path, path: "a.txt") == "one\n")
  #expect(GitChanges.headText(root: dir.path, path: "b.txt") == nil)
}

@Test func aFolderOutsideGitHasNoChangesList() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  #expect(GitChanges.status(root: dir.path) == nil)
  #expect(GitChanges.headText(root: dir.path, path: "x") == nil)
}

@Test func splitsStagedFromUnstagedChanges() {
  let output = " M a\0M  b\0MM c\0A  d\0?? e\0R  new\0old\0 D f\0UU g\0AD h\0!! i\0"
  let lists = GitChanges.parseLists(output)
  #expect(lists.staged == [
    .init(path: "b", status: .modified), .init(path: "c", status: .modified), .init(path: "d", status: .added),
    .init(path: "h", status: .added), .init(path: "new", status: .renamed, oldPath: "old"),
  ])
  #expect(lists.unstaged == [
    .init(path: "a", status: .modified), .init(path: "c", status: .modified), .init(path: "e", status: .untracked),
    .init(path: "f", status: .deleted), .init(path: "g", status: .modified), .init(path: "h", status: .deleted),
  ])
  #expect(GitChanges.parseLists("") == .init(staged: [], unstaged: []))
}

@Test func stagesUnstagesRevertsAndCommitsInARealRepository() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  try git(dir, "init", "-q")
  try git(dir, "config", "user.name", "t")
  try git(dir, "config", "user.email", "t@t")
  try git(dir, "config", "commit.gpgsign", "false")
  let file = { (name: String) in dir.appendingPathComponent(name) }
  try "one\n".write(to: file("a.txt"), atomically: true, encoding: .utf8)
  try "keep\n".write(to: file("c [x].txt"), atomically: true, encoding: .utf8)
  try git(dir, "add", ".")
  try git(dir, "commit", "-q", "-m", "feat: first")

  try "two\n".write(to: file("a.txt"), atomically: true, encoding: .utf8)
  try "new\n".write(to: file("b.txt"), atomically: true, encoding: .utf8)
  try "changed\n".write(to: file("c [x].txt"), atomically: true, encoding: .utf8)
  #expect(GitChanges.stage(root: dir.path, paths: ["a.txt", "b.txt"]) == nil)
  try "three\n".write(to: file("a.txt"), atomically: true, encoding: .utf8)
  let lists = try #require(GitChanges.lists(root: dir.path))
  #expect(lists.staged == [.init(path: "a.txt", status: .modified), .init(path: "b.txt", status: .added)])
  #expect(lists.unstaged == [.init(path: "a.txt", status: .modified), .init(path: "c [x].txt", status: .modified)])
  #expect(GitChanges.indexText(root: dir.path, path: "a.txt") == "two\n")
  #expect(GitChanges.indexText(root: dir.path, path: "nope.txt") == nil)

  let draft = try #require(GitChanges.draftContext(root: dir.path))
  #expect(draft.staged && draft.diff.contains("+two") && !draft.diff.contains("changed"))
  #expect(draft.recent == ["feat: first"])

  // Reverting goes back to the staged text; a pathspec-looking name is taken literally.
  #expect(GitChanges.discard(root: dir.path, tracked: ["a.txt", "c [x].txt"], untracked: []) == nil)
  #expect(try String(contentsOf: file("a.txt"), encoding: .utf8) == "two\n")
  #expect(try String(contentsOf: file("c [x].txt"), encoding: .utf8) == "keep\n")

  #expect(GitChanges.unstage(root: dir.path, paths: ["b.txt"]) == nil)
  #expect(GitChanges.lists(root: dir.path)?.unstaged == [.init(path: "b.txt", status: .untracked)])
  #expect(GitChanges.commit(root: dir.path, message: "fix: second\n\nbody") == nil)
  #expect(GitChanges.lists(root: dir.path)?.staged == [])
  #expect(GitChanges.draftContext(root: dir.path)?.recent == ["fix: second", "feat: first"])
  #expect(GitChanges.commit(root: dir.path, message: "nothing staged") != nil)
  #expect(GitChanges.discard(root: dir.path, tracked: [], untracked: ["../escape.txt"]) != nil)
}

@Test func unstagesInARepositoryWithNoCommitsYet() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  try git(dir, "init", "-q")
  try "x\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
  #expect(GitChanges.stage(root: dir.path, paths: ["a.txt"]) == nil)
  #expect(GitChanges.lists(root: dir.path)?.staged == [.init(path: "a.txt", status: .added)])
  let draft = try #require(GitChanges.draftContext(root: dir.path))
  #expect(draft.recent == [] && draft.diff.contains("+x"))
  #expect(GitChanges.unstage(root: dir.path, paths: ["a.txt"]) == nil)
  #expect(GitChanges.lists(root: dir.path) == .init(staged: [], unstaged: [.init(path: "a.txt", status: .untracked)]))
}
