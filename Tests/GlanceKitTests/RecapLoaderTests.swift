import Foundation
import GlanceCore
import Testing
@testable import GlanceKit

// RecapLoader on a real temporary repository and a small Claude Code transcript. No summaries are stored for the random
// session ids, no gh runs (the PR commits are injected) and no Claude is started.

/// A scratch folder holding a repository, the Claude projects folder and a work store, removed afterwards.
private final class Scratch {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("recap-loader-\(UUID().uuidString)")
  var repo: String { root.appendingPathComponent("repo").path }
  var projects: String { root.appendingPathComponent("projects").path }
  var store: WorkStore { WorkStore(folder: root.appendingPathComponent("work")) }

  init() { try? FileManager.default.createDirectory(atPath: root.appendingPathComponent("repo").path, withIntermediateDirectories: true) }
  deinit { try? FileManager.default.removeItem(at: root) }

  @discardableResult
  func git(_ arguments: [String]) -> Bool {
    GitRun.data(repo, ["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"] + arguments) != nil
  }

  func commit(_ file: String, lines: Int, message: String) {
    let text = (0..<lines).map { "line \($0)" }.joined(separator: "\n") + "\n"
    try? text.write(toFile: repo + "/" + file, atomically: true, encoding: .utf8)
    git(["add", file])
    git(["commit", "-q", "-m", message])
  }

  /// A repository whose remote default branch is `main`, with two commits on `feat/x` after it.
  func repoWithABranch(remote: Bool = true) {
    git(["init", "-q", "-b", "main"])
    commit("a.txt", lines: 1, message: "start")
    if remote {
      git(["update-ref", "refs/remotes/origin/main", "HEAD"])
      git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
    }
    git(["checkout", "-q", "-b", "feat/x"])
    commit("b.txt", lines: 3, message: "add b")
    commit("c.txt", lines: 1, message: "add c")
  }

  /// A transcript in Claude's own format, filed where Claude files it for `folder`.
  func transcript(session: String, folder: String) {
    let directory = projects + "/" + ClaudeProjectFolder.name(for: folder)
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let lines = [
      #"{"type":"user","uuid":"u1","timestamp":"2026-11-01T10:00:00.000Z","message":{"role":"user","content":"add b and c"}}"#,
      #"{"type":"assistant","uuid":"a1","timestamp":"2026-11-01T10:00:02.000Z","message":{"id":"m1","role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"Done."}],"stop_reason":"end_turn","usage":{"input_tokens":10,"cache_read_input_tokens":40000,"cache_creation_input_tokens":2000,"output_tokens":50}}}"#,
    ]
    try? (lines.joined(separator: "\n") + "\n").write(toFile: directory + "/\(session).jsonl", atomically: true, encoding: .utf8)
  }
}

private func input(_ scratch: Scratch, exists: Bool = true, branch: String? = "feat/x", sessions: [String], pr: BoardPR? = nil) -> RecapLoader.Input {
  RecapLoader.Input(worktree: scratch.repo, exists: exists, branch: branch, main: scratch.repo, sessions: sessions, title: "Add b and c", pr: pr)
}

@Test func theLogTheDiffAndTheSpendComeFromGitAndTheTranscript() {
  let scratch = Scratch()
  scratch.repoWithABranch()
  let session = UUID().uuidString.lowercased()
  scratch.transcript(session: session, folder: scratch.repo)

  let recap = RecapLoader.load(input(scratch, sessions: [session]), store: scratch.store, projects: scratch.projects,
                               prCommits: { _, _ in Issue.record("the PR is asked only when git has no commits"); return [] })

  #expect(recap.title == "Add b and c")
  #expect(recap.commits.map(\.subject) == ["add c", "add b"])
  #expect(recap.files == 2)
  #expect(recap.added == 4)
  #expect(recap.removed == 0)
  #expect(recap.bullets.isEmpty)
  #expect(recap.source == "From git log")
  #expect(recap.unsummarized == [session])
  #expect((recap.spend ?? 0) > 0)
}

@Test func aSessionWithNoTranscriptLeavesTheSpendOutAndIsNotOfferedASummary() {
  let scratch = Scratch()
  scratch.repoWithABranch()
  let session = UUID().uuidString.lowercased()

  let recap = RecapLoader.load(input(scratch, sessions: [session]), store: scratch.store, projects: scratch.projects)

  #expect(recap.spend == nil)
  #expect(recap.unsummarized.isEmpty)
  #expect(recap.commits.count == 2)
}

@Test func aBranchThatIsGoneTakesItsCommitsFromThePullRequest() {
  let scratch = Scratch()
  scratch.repoWithABranch()
  var asked: (Int, String)?
  let pr = BoardPR(number: 12, merged: true, checks: .passing)

  let recap = RecapLoader.load(input(scratch, exists: false, branch: "deleted-after-merge", sessions: [], pr: pr),
                               store: scratch.store, projects: scratch.projects,
                               prCommits: { number, folder in
                                 asked = (number, folder)
                                 return [WorktreeRecap.Commit(hash: "abc1234", subject: "from the PR")]
                               })

  // A removed worktree is read from the main checkout.
  #expect(asked?.0 == 12)
  #expect(asked?.1 == scratch.repo)
  #expect(recap.commits == [WorktreeRecap.Commit(hash: "abc1234", subject: "from the PR")])
  #expect(recap.files == nil)
  #expect(recap.source == "From git log · #12")
}

@Test func withoutARemoteDefaultBranchTheCurrentBranchIsNeverTheBase() {
  let scratch = Scratch()
  scratch.repoWithABranch(remote: false)

  let recap = RecapLoader.load(input(scratch, sessions: []), store: scratch.store, projects: scratch.projects,
                               prCommits: { _, _ in Issue.record("no PR was given"); return [] })

  // Against itself the log would be empty and the diff empty: no commits and no change line, not "0 files".
  #expect(recap.commits.isEmpty)
  #expect(recap.files == nil)
  #expect(recap.source == nil)
}

@Test func aBranchNamedLikeAnOptionRunsNoGit() {
  let scratch = Scratch()
  scratch.repoWithABranch()

  let recap = RecapLoader.load(input(scratch, branch: "--output=/tmp/pwned", sessions: []), store: scratch.store, projects: scratch.projects)

  #expect(recap.commits.isEmpty)
  #expect(recap.files == nil)
}

// MARK: Bounded work

@Test func theNewestFiftySessionsAreReadAndTheRestAreCounted() {
  let scratch = Scratch()
  scratch.repoWithABranch()
  let sessions = (0..<60).map { _ in UUID().uuidString.lowercased() }
  // The newest are first; only the ones read have a transcript here.
  for id in sessions { scratch.transcript(session: id, folder: scratch.repo) }

  let recap = RecapLoader.load(input(scratch, sessions: sessions), store: scratch.store, projects: scratch.projects)

  #expect(recap.sessions == Array(sessions.prefix(RecapText.sessionsRead)))
  #expect(recap.older == 10)
  #expect(recap.unsummarized == Array(sessions.prefix(RecapText.sessionsRead)))
  // A reload passes the count back and keeps adding to it.
  var again = input(scratch, sessions: recap.sessions)
  again.older = recap.older
  #expect(RecapLoader.load(again, store: scratch.store, projects: scratch.projects).older == 10)
}

@Test func whatIsKnownIsPublishedBeforeTheSpendIsRead() {
  let scratch = Scratch()
  scratch.repoWithABranch()
  let session = UUID().uuidString.lowercased()
  scratch.transcript(session: session, folder: scratch.repo)
  var published: [WorktreeRecap] = []

  let final = RecapLoader.load(input(scratch, sessions: [session]), store: scratch.store, projects: scratch.projects,
                               partial: { published.append($0) })

  let early = try? #require(published.first)
  #expect(published.count == 1)
  #expect(early?.commits.count == 2)
  #expect(early?.unsummarized == [session])
  #expect(early?.spend == nil)
  #expect(early?.spendPending == true)
  #expect(final.spendPending == false)
  #expect((final.spend ?? 0) > 0)
}

@Test func aSecondLoadOfTheSameTranscriptsReadsNoneOfThem() throws {
  let scratch = Scratch()
  scratch.repoWithABranch()
  let session = UUID().uuidString.lowercased()
  scratch.transcript(session: session, folder: scratch.repo)
  let first = RecapLoader.load(input(scratch, sessions: [session]), store: scratch.store, projects: scratch.projects)
  // The transcript is gone from under the same name and size: the cached figure stands only if size and time are the same.
  var published: [WorktreeRecap] = []
  let second = RecapLoader.load(input(scratch, sessions: [session]), store: scratch.store, projects: scratch.projects,
                                partial: { published.append($0) })
  #expect(second.spend == first.spend)
  // Nothing left to read, so the cheap parts and the spend arrive together.
  #expect(published.isEmpty)
}

@Test func aCancelledLoadReturnsWhatItHadWithoutSpend() {
  let scratch = Scratch()
  scratch.repoWithABranch()
  let session = UUID().uuidString.lowercased()
  scratch.transcript(session: session, folder: scratch.repo)
  let recap = RecapLoader.load(input(scratch, sessions: [session]), store: scratch.store, projects: scratch.projects,
                               isCancelled: { true })
  #expect(recap.spend == nil)
}

@Test func aRemovedWorktreeSaysWhetherItsBranchStillExists() {
  let scratch = Scratch()
  scratch.repoWithABranch()
  let kept = RecapLoader.load(input(scratch, exists: false, branch: "feat/x", sessions: []), store: scratch.store, projects: scratch.projects)
  let gone = RecapLoader.load(input(scratch, exists: false, branch: "deleted-after-merge", sessions: []), store: scratch.store, projects: scratch.projects)
  let present = RecapLoader.load(input(scratch, exists: true, branch: "feat/x", sessions: []), store: scratch.store, projects: scratch.projects)
  #expect(kept.branchExists == true)
  #expect(gone.branchExists == false)
  // Only a removed worktree is asked.
  #expect(present.branchExists == nil)
}

@Test func whatIsKnownIsPublishedBeforeGhIsAsked() {
  let scratch = Scratch()
  scratch.repoWithABranch()
  var order: [String] = []
  let pr = BoardPR(number: 12, merged: true, checks: .passing)

  let final = RecapLoader.load(input(scratch, exists: false, branch: "deleted-after-merge", sessions: [], pr: pr),
                               store: scratch.store, projects: scratch.projects,
                               prCommits: { _, _ in order.append("gh"); return [WorktreeRecap.Commit(hash: "abc1234", subject: "from the PR")] },
                               partial: { early in order.append(early.commits.isEmpty ? "partial" : "partial with commits") })

  // The recap shows what it has before gh (which can take 20 s) answers; the commits fill in after.
  #expect(order == ["partial", "gh"])
  #expect(final.commits.count == 1)
  #expect(final.source == "From git log · #12")
}
