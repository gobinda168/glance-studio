import Foundation
import Testing
@testable import GlanceCore

private func context(_ files: [AttributedFile], live: [String] = []) -> WorktreeWarnings.Context {
  WorktreeWarnings.Context(
    me: "me", files: files,
    live: live.map { TrackedSession(id: $0, worktree: "/w", branch: nil, pid: 1, terminal: "Warp", task: nil,
                                    started: .distantPast, ended: nil) },
    name: { $0 == "other" ? "Release beta.18" : $0 })
}

struct WorktreeWarningsTests {
  @Test func foreignEditsNamesOtherSessionsAndOutsideChanges() {
    let files = [AttributedFile(path: "Info.plist", status: ".M", author: .session("other")),
                 AttributedFile(path: "README.md", status: ".M", author: .outside),
                 AttributedFile(path: "mine.swift", status: ".M", author: .session("me"))]
    let warning = WorktreeWarnings.foreignEdits(context(files))
    #expect(warning?.items == ["Info.plist", "README.md"])
    #expect(warning?.text.contains("Release beta.18: Info.plist") == true)
    #expect(warning?.text.contains("changed outside Claude: README.md") == true)
    #expect(warning?.text.contains(WorktreeWarnings.fixes) == true)
    #expect(WorktreeWarnings.foreignEdits(context([files[2]])) == nil)
  }

  @Test func sharedWorktreeNamesTheOtherLiveSessions() {
    #expect(WorktreeWarnings.sharedWorktree(context([], live: ["me"])) == nil)
    let warning = WorktreeWarnings.sharedWorktree(context([], live: ["me", "other"]))
    #expect(warning?.items == ["other"])
    #expect(warning?.text.contains("Release beta.18 (Warp)") == true)
  }

  @Test func topicsGroupsTheWholeDiffByAuthor() {
    let files = [AttributedFile(path: "a", status: ".M", author: .session("me")),
                 AttributedFile(path: "b", status: ".M", author: .session("other"))]
    let warning = WorktreeWarnings.topics(context(files))
    #expect(warning?.text.contains("this session: a") == true)
    #expect(warning?.text.contains("Release beta.18: b") == true)
    #expect(WorktreeWarnings.topics(context([])) == nil)
  }

  @Test func aWarningIsToldOncePerStateAndAgainWhenItGrows() {
    var told: [String: [String]] = [:]
    let one = WorktreeWarning(kind: .foreignEdits, items: ["a"], text: "1")
    #expect(WorktreeWarnings.unseen([one], told: &told) == [one])
    #expect(WorktreeWarnings.unseen([one], told: &told).isEmpty)
    let two = WorktreeWarning(kind: .foreignEdits, items: ["a", "b"], text: "2")
    #expect(WorktreeWarnings.unseen([two], told: &told) == [two])
    // Shrinking (a file committed) doesn't repeat it.
    #expect(WorktreeWarnings.unseen([one], told: &told).isEmpty)
  }

  @Test func recognisesCommits() {
    #expect(WorktreeWarnings.isCommit("git commit -m 'x'"))
    #expect(WorktreeWarnings.isCommit("cd app && git -C /r commit -am x"))
    #expect(!WorktreeWarnings.isCommit("git commit-tree abc"))
    #expect(!WorktreeWarnings.isCommit("echo git"))
    #expect(!WorktreeWarnings.isCommit(nil))
  }
}
