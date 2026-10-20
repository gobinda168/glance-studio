import Foundation
import Testing
@testable import GlanceCore

private func reviewThread(_ body: String, author: String = "claude", path: String = "scripts/release.sh",
                          line: Int? = 123) -> ReviewThreads.Thread {
  .init(id: "t-\(line ?? 0)", isResolved: false, isOutdated: false, path: path, line: line, startLine: nil, side: .right,
        resolvedBy: nil, comments: [.init(id: "c", databaseID: 1, author: author, isBot: false, body: body,
                                          createdAt: nil, reviewState: .commented)])
}

@Test func aProgramRunsWithExtraEnvironment() throws {
  let result = try #require(GitHubCLI.execute("/usr/bin/env", [], environment: ["GLANCE_FIX_TEST": "yes"]))
  #expect(result.status == 0)
  #expect(String(decoding: result.output, as: UTF8.self).contains("GLANCE_FIX_TEST=yes"))
}

@Test func changesAreReadFromNameStatusWithNulls() {
  #expect(FixPatch.parseChanges("M\0keep.txt\0A\0new file.txt\0D\0old.txt\0T\0link\0") == [
    .init(path: "keep.txt", kind: .modified), .init(path: "new file.txt", kind: .added),
    .init(path: "old.txt", kind: .deleted), .init(path: "link", kind: .modified),
  ])
  #expect(FixPatch.parseChanges("").isEmpty)
  #expect(FixPatch.names("a.txt\0b c.txt\0") == ["a.txt", "b c.txt"])
}

@Test func aFailureSaysWhatGitRefused() {
  let rejected = """
    To github.com:gobinda168/glance.git
     ! [rejected]        release -> release (fetch first)
    error: failed to push some refs to 'github.com:gobinda168/glance.git'
    hint: Updates were rejected because the remote contains work that you do not have locally.
    """
  #expect(FixPatch.failureLine(rejected) == "! [rejected]        release -> release (fetch first)")
  #expect(FixPatch.failureLine("warning: x\nfatal: No configured push destination.\n")
    == "fatal: No configured push destination.")
  #expect(FixPatch.failureLine("\nsomething odd\n") == "something odd")
  #expect(FixPatch.failureLine("") == "git failed")
}

@Test func theUsersOwnEditsOverlapTheFixWhereBothChangedAFile() {
  let user: [FixPatch.Change] = [.init(path: "keep.txt", kind: .modified), .init(path: "mine.txt", kind: .added)]
  let claude: [FixPatch.Change] = [.init(path: "new.txt", kind: .added), .init(path: "keep.txt", kind: .modified)]
  #expect(FixPatch.overlap(user: user, claude: claude) == ["keep.txt"])
  #expect(FixPatch.overlap(user: [], claude: claude).isEmpty)
}

@Test func aFixCommitSaysWhatItAddressesWithClaudeAsCoAuthor() {
  let one = reviewThread("**Blocking:** roll the release back when the upload fails.\nMore words.")
  #expect(FixPatch.commitMessage([one]) == """
    Address review: Blocking: roll the release back when the upload fails.

    - scripts/release.sh:123 (claude): Blocking: roll the release back when the upload fails.

    Co-Authored-By: Claude <noreply@anthropic.com>
    """)
  let long = reviewThread(String(repeating: "word ", count: 20), author: "devon", path: "docs/testing.md", line: 14)
  let two = FixPatch.commitMessage([one, long])
  #expect(two.hasPrefix("Address 2 review comments\n\n- scripts/release.sh:123 (claude): "))
  #expect(two.contains("- docs/testing.md:14 (devon): " + String(repeating: "word ", count: 12).prefix(59) + "…"))
  #expect(FixPatch.suggestionMessage(reviewThread("x", author: "devon")) == "Apply suggestion from devon on scripts/release.sh:123")
  #expect(FixPatch.suggestionMessage(reviewThread("x", line: nil)) == "Apply suggestion from claude on scripts/release.sh")
  #expect(FixPatch.reply(sha: "abc1234") == "Fixed in abc1234.")
}

@Test func gitIsAskedForSnapshotsChangesCommitsAndRestores() {
  #expect(FixPatch.indexPathArguments() == ["rev-parse", "--git-path", "index"])
  #expect(FixPatch.addAllArguments() == ["add", "-A"])
  #expect(FixPatch.writeTreeArguments() == ["write-tree"])
  #expect(FixPatch.changesArguments(from: "a1", to: "b2")
    == ["diff-tree", "-r", "--no-renames", "--name-status", "-z", "a1", "b2"])
  #expect(FixPatch.patchArguments(from: "a1", to: "b2") == ["diff", "--no-color", "--no-ext-diff", "--no-renames",
                                                            "--src-prefix=a/", "--dst-prefix=b/", "a1", "b2"])
  #expect(FixPatch.addArguments(["a.txt"]) == ["add", "-A", "--", "a.txt"])
  #expect(FixPatch.trackedArguments(["old.txt"]) == ["ls-tree", "-r", "--name-only", "-z", "HEAD", "--", "old.txt"])
  #expect(FixPatch.commitArguments(message: "M", paths: ["a.txt"]) == ["commit", "--only", "-m", "M", "--", "a.txt"])
  #expect(FixPatch.shortHeadArguments() == ["rev-parse", "--short", "HEAD"])
  #expect(FixPatch.pushArguments() == ["push"])
  #expect(FixPatch.restoreArguments(source: "a1", paths: ["a.txt"]) == ["restore", "--source=a1", "--worktree", "--", "a.txt"])
}
