import Foundation
import Testing
@testable import GlanceCore

private struct ActionScratch {
  let base = FileManager.default.temporaryDirectory.appendingPathComponent("wt-\(UUID().uuidString)")
  var main: String { base.appendingPathComponent("app").path }

  init() throws {
    try FileManager.default.createDirectory(atPath: base.appendingPathComponent("app").path,
                                            withIntermediateDirectories: true)
    try run("init", "-q", "-b", "main")
    // WorktreeActions runs git with this process's environment: the identity lives in the repository's config.
    try run("config", "user.name", "t")
    try run("config", "user.email", "t@t")
    try "hello\n".write(toFile: main + "/README.md", atomically: true, encoding: .utf8)
    try run("add", ".")
    try run("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "first")
  }

  @discardableResult
  func run(_ arguments: String..., in root: String? = nil) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root ?? main] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.environment = ["GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                           "GIT_COMMITTER_EMAIL": "t@t", "HOME": NSHomeDirectory()]
    try process.run()
    process.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  }
}

struct WorktreeActionsTests {
  @Test func slugsTaskNames() {
    #expect(WorktreeActions.slug("Fix the shell tests!") == "fix-the-shell-tests")
    #expect(WorktreeActions.slug("  ") == "task")
    #expect(WorktreeActions.slug(String(repeating: "a", count: 60)).count == 40)
  }

  @Test func createsAWorktreeBesideTheRepository() throws {
    let repo = try ActionScratch()
    defer { try? FileManager.default.removeItem(at: repo.base) }
    let made = try WorktreeActions.create(repoRoot: repo.main, task: "Fix shell tests", from: nil).get()
    #expect(made.path == repo.base.appendingPathComponent("app-fix-shell-tests").path)
    #expect(made.branch == "fix-shell-tests")
    #expect(FileManager.default.fileExists(atPath: made.path + "/README.md"))
    // The same name again gets a numbered folder and branch.
    let again = try WorktreeActions.create(repoRoot: repo.main, task: "Fix shell tests", from: nil).get()
    #expect(again.branch == "fix-shell-tests-2")
  }

  @Test func aNewBranchDoesntTrackTheRemoteItStartsFrom() throws {
    let repo = try ActionScratch()
    defer { try? FileManager.default.removeItem(at: repo.base) }
    let clone = repo.base.appendingPathComponent("clone").path
    try repo.run("clone", "-q", repo.main, clone)
    #expect(WorktreeActions.defaultBase(repoRoot: clone) == "origin/main")
    let made = try WorktreeActions.create(repoRoot: clone, task: "own branch", from: nil).get()
    #expect(try repo.run("config", "--get", "branch.\(made.branch).merge", in: clone).isEmpty)
    #expect(try repo.run("config", "--get", "branch.\(made.branch).remote", in: clone).isEmpty)
  }

  @Test func commitsOnlyTheGivenFiles() throws {
    let repo = try ActionScratch()
    defer { try? FileManager.default.removeItem(at: repo.base) }
    try "a\n".write(toFile: repo.main + "/mine.txt", atomically: true, encoding: .utf8)
    try "b\n".write(toFile: repo.main + "/theirs.txt", atomically: true, encoding: .utf8)
    #expect(WorktreeActions.commit(worktree: repo.main, files: ["mine.txt"], message: "mine") == nil)
    let status = try repo.run("status", "--porcelain")
    #expect(status.contains("theirs.txt"))
    #expect(!status.contains("mine.txt"))
  }

  @Test func movesASessionsFilesToANewWorktree() throws {
    let repo = try ActionScratch()
    defer { try? FileManager.default.removeItem(at: repo.base) }
    try "changed\n".write(toFile: repo.main + "/README.md", atomically: true, encoding: .utf8)
    try "new\n".write(toFile: repo.main + "/new.txt", atomically: true, encoding: .utf8)
    try "stay\n".write(toFile: repo.main + "/stay.txt", atomically: true, encoding: .utf8)
    let files = [AttributedFile(path: "README.md", status: ".M", author: .session("s1")),
                 AttributedFile(path: "new.txt", status: "??", author: .session("s1"))]
    let moved = try WorktreeActions.move(files: files, from: repo.main, task: "split out").get()
    #expect(try String(contentsOfFile: moved.path + "/README.md", encoding: .utf8) == "changed\n")
    #expect(FileManager.default.fileExists(atPath: moved.path + "/new.txt"))
    #expect(try String(contentsOfFile: repo.main + "/README.md", encoding: .utf8) == "hello\n")
    #expect(!FileManager.default.fileExists(atPath: repo.main + "/new.txt"))
    #expect(FileManager.default.fileExists(atPath: repo.main + "/stay.txt"))
  }

  @Test func removesOnlyAMergedCleanWorktree() throws {
    let repo = try ActionScratch()
    defer { try? FileManager.default.removeItem(at: repo.base) }
    let made = try WorktreeActions.create(repoRoot: repo.main, task: "done", from: nil).get()
    #expect(WorktreeActions.isMerged(branch: made.branch, mainRoot: repo.main))
    try "dirty\n".write(toFile: made.path + "/x.txt", atomically: true, encoding: .utf8)
    #expect(WorktreeActions.remove(worktree: made.path, branch: made.branch, mainRoot: repo.main) != nil)
    try FileManager.default.removeItem(atPath: made.path + "/x.txt")
    #expect(WorktreeActions.remove(worktree: made.path, branch: made.branch, mainRoot: repo.main) == nil)
    #expect(!FileManager.default.fileExists(atPath: made.path))
  }

  @Test func aMoveThatCannotCopyLeavesTheSourceUntouched() throws {
    let repo = try ActionScratch()
    defer { try? FileManager.default.removeItem(at: repo.base) }
    try "changed\n".write(toFile: repo.main + "/README.md", atomically: true, encoding: .utf8)
    // README.md applies cleanly; ghost.txt is listed as untracked but doesn't exist, so the copy fails afterwards.
    let files = [AttributedFile(path: "README.md", status: ".M", author: .session("s1")),
                 AttributedFile(path: "ghost.txt", status: "??", author: .session("s1"))]
    let result = WorktreeActions.move(files: files, from: repo.main, task: "split out")
    guard case .failure = result else {
      Issue.record("expected the move to fail")
      return
    }
    #expect(try String(contentsOfFile: repo.main + "/README.md", encoding: .utf8) == "changed\n")
    #expect(try repo.run("worktree", "list", "--porcelain").components(separatedBy: "worktree ").count == 2)
    #expect(try repo.run("branch", "--list").split(separator: "\n").count == 1)
    #expect(!FileManager.default.fileExists(atPath: repo.base.appendingPathComponent("app-split-out").path))
  }

  @Test func aMoveThatCannotReadTheChangesCreatesNothing() throws {
    let repo = try ActionScratch()
    defer { try? FileManager.default.removeItem(at: repo.base) }
    // A path outside the repository makes `git diff` fail.
    let files = [AttributedFile(path: "../outside.txt", status: ".M", author: .session("s1"))]
    guard case .failure = WorktreeActions.move(files: files, from: repo.main, task: "split out") else {
      Issue.record("expected the move to fail")
      return
    }
    #expect(try repo.run("worktree", "list", "--porcelain").components(separatedBy: "worktree ").count == 2)
    #expect(try repo.run("branch", "--list").split(separator: "\n").count == 1)
  }

  @Test func movesStagedNewBinaryDeletedAndNestedFiles() throws {
    let repo = try ActionScratch()
    defer { try? FileManager.default.removeItem(at: repo.base) }
    let binary = Data([0x00, 0xFF, 0xFE, 0x80, 0x01])
    try binary.write(to: URL(fileURLWithPath: repo.main + "/blob.bin"))
    try "doomed\n".write(toFile: repo.main + "/gone.txt", atomically: true, encoding: .utf8)
    try repo.run("add", ".")
    try repo.run("commit", "-qm", "more")
    try Data([0x00, 0xFF, 0xFE, 0x80, 0x02, 0x03]).write(to: URL(fileURLWithPath: repo.main + "/blob.bin"))
    try FileManager.default.removeItem(atPath: repo.main + "/gone.txt")
    try "staged\n".write(toFile: repo.main + "/added.txt", atomically: true, encoding: .utf8)
    try repo.run("add", "added.txt")
    // Staged, then edited again: the index and the file differ.
    try "staged twice\n".write(toFile: repo.main + "/added2.txt", atomically: true, encoding: .utf8)
    try repo.run("add", "added2.txt")
    try "staged and edited\n".write(toFile: repo.main + "/added2.txt", atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(atPath: repo.main + "/sub/dir", withIntermediateDirectories: true)
    try "nested\n".write(toFile: repo.main + "/sub/dir/file.txt", atomically: true, encoding: .utf8)
    let mine: [(String, String)] = [("blob.bin", ".M"), ("gone.txt", ".D"), ("added.txt", "A."), ("added2.txt", "AM"),
                                    ("sub/dir/file.txt", "??")]
    let files = mine.map { AttributedFile(path: $0.0, status: $0.1, author: .session("s1")) }
    let moved = try WorktreeActions.move(files: files, from: repo.main, task: "mixed").get()

    #expect(try Data(contentsOf: URL(fileURLWithPath: moved.path + "/blob.bin")) == Data([0x00, 0xFF, 0xFE, 0x80, 0x02, 0x03]))
    #expect(!FileManager.default.fileExists(atPath: moved.path + "/gone.txt"))
    #expect(try String(contentsOfFile: moved.path + "/added.txt", encoding: .utf8) == "staged\n")
    #expect(try String(contentsOfFile: moved.path + "/added2.txt", encoding: .utf8) == "staged and edited\n")
    #expect(try String(contentsOfFile: moved.path + "/sub/dir/file.txt", encoding: .utf8) == "nested\n")

    // The source is clean again for all of them.
    #expect(try repo.run("status", "--porcelain").isEmpty)
    #expect(try Data(contentsOf: URL(fileURLWithPath: repo.main + "/blob.bin")) == binary)
    #expect(FileManager.default.fileExists(atPath: repo.main + "/gone.txt"))
    #expect(!FileManager.default.fileExists(atPath: repo.main + "/added.txt"))
  }

  @Test func pathsWithGlobCharactersAreTakenLiterally() throws {
    let repo = try ActionScratch()
    defer { try? FileManager.default.removeItem(at: repo.base) }
    for folder in ["app/[id]", "app/i"] {
      try FileManager.default.createDirectory(atPath: repo.main + "/" + folder, withIntermediateDirectories: true)
      try "page\n".write(toFile: repo.main + "/" + folder + "/page.tsx", atomically: true, encoding: .utf8)
    }
    // As a glob, "app/[id]/page.tsx" would match "app/i/page.tsx" too.
    #expect(WorktreeActions.commit(worktree: repo.main, files: ["app/[id]/page.tsx"], message: "id page") == nil)
    let status = try repo.run("status", "--porcelain", "--untracked-files=all")
    #expect(status.contains("app/i/page.tsx"))
    #expect(!status.contains("app/[id]/page.tsx"))
  }

  @Test func movesWithColouredDiffsConfigured() throws {
    let repo = try ActionScratch()
    defer { try? FileManager.default.removeItem(at: repo.base) }
    try repo.run("config", "color.diff", "always")
    try "changed\n".write(toFile: repo.main + "/README.md", atomically: true, encoding: .utf8)
    let files = [AttributedFile(path: "README.md", status: ".M", author: .session("s1"))]
    let moved = try WorktreeActions.move(files: files, from: repo.main, task: "colour").get()
    #expect(try String(contentsOfFile: moved.path + "/README.md", encoding: .utf8) == "changed\n")
    #expect(try String(contentsOfFile: repo.main + "/README.md", encoding: .utf8) == "hello\n")
  }

  @Test func keepsAnUnmergedBranchWhenRemoving() throws {
    let repo = try ActionScratch()
    defer { try? FileManager.default.removeItem(at: repo.base) }
    let made = try WorktreeActions.create(repoRoot: repo.main, task: "unmerged", from: nil).get()
    try "work\n".write(toFile: made.path + "/work.txt", atomically: true, encoding: .utf8)
    #expect(WorktreeActions.commit(worktree: made.path, files: ["work.txt"], message: "work") == nil)
    #expect(!WorktreeActions.isMerged(branch: made.branch, mainRoot: repo.main))
    let failure = WorktreeActions.remove(worktree: made.path, branch: made.branch, mainRoot: repo.main)
    #expect(failure?.message.contains(made.branch) == true)
    #expect(!FileManager.default.fileExists(atPath: made.path))
    #expect(try repo.run("branch", "--list", made.branch).contains(made.branch))
  }
}
