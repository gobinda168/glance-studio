import Foundation
import Testing
@testable import GlanceCore

@Suite struct BoardEntriesTests {
  let t0 = Date(timeIntervalSince1970: 100), t1 = Date(timeIntervalSince1970: 200)
  let surfaceA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
  let surfaceB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

  func session(_ id: String, worktree: String = "/r/wt", terminal: String? = "WarpTerminal", ended: Date? = nil) -> TrackedSession {
    TrackedSession(id: id, worktree: worktree, branch: "feat/x", pid: 1, terminal: terminal, task: "do it", started: t0, ended: ended)
  }
  func tree(_ sessions: [TrackedSession], live: Set<String>, path: String = "/r/wt", warning: Bool = false,
            orphans: [TrackedSession] = []) -> RepoTree {
    let info = WorktreeInfo(path: path, branch: "feat/x", isMain: false, files: [], sessions: sessions, live: live,
                            merged: false, tooMany: false, warning: warning, added: 0, removed: 0)
    return RepoTree(repo: "/r/.git", name: "acme", main: "/r", worktrees: [info], orphans: orphans)
  }
  func link(_ id: String, _ surface: UUID, cwd: String? = "/r/wt") -> SessionLink {
    SessionLink(surface: surface, sessionID: id, transcriptPath: "/t/\(id).jsonl", cwd: cwd, source: "startup")
  }

  @Test func aLiveLedgerSessionWithALinkIsInStudio() {
    let entries = BoardEntries.merge(trees: [tree([session("a", terminal: "studio:x")], live: ["a"])],
                                     links: [link("a", surfaceA)], waiting: [])
    #expect(entries.count == 1)
    #expect(entries[0].place == .studio(surface: surfaceA))
    #expect(entries[0].project == "acme")
    #expect(entries[0].transcript == "/t/a.jsonl")
    #expect(entries[0].live)
  }

  @Test func aSessionInAnotherTerminalIsReadOnly() {
    let entries = BoardEntries.merge(trees: [tree([session("a")], live: ["a"])], links: [], waiting: [])
    #expect(entries[0].place == .external("Warp"))
  }

  @Test func oneSessionInTwoTabsIsOneCardOnTheWaitingSplit() {
    let trees = [tree([session("a")], live: ["a"])]
    let links = [link("a", surfaceA), link("a", surfaceB)]
    #expect(BoardEntries.merge(trees: trees, links: links, waiting: [surfaceB]).map(\.place) == [.studio(surface: surfaceB)])
    // Nothing waiting: the same split every refresh.
    #expect(BoardEntries.merge(trees: trees, links: links.reversed(), waiting: []).map(\.place) == [.studio(surface: surfaceA)])
  }

  @Test func aLinkedTabOutsideGitStillGetsACard() {
    let entries = BoardEntries.merge(trees: [], links: [link("a", surfaceA, cwd: "/tmp/notes")], waiting: [])
    #expect(entries.count == 1)
    #expect(entries[0].project == "notes")
    #expect(entries[0].live)
    #expect(entries[0].branch == nil)
  }

  @Test func aLinkedTabWhoseClaudeExitedIsEndedNotLive() {
    let facts = ["a": LinkOnlyFacts(running: false, started: t0, lastActive: t1)]
    let entries = BoardEntries.merge(trees: [], links: [link("a", surfaceA, cwd: "/tmp/notes")], waiting: [], linkOnly: facts)
    #expect(entries.count == 1)
    #expect(!entries[0].live)
    #expect(entries[0].place == .nowhere)
    #expect(entries[0].started == t0)
    #expect(entries[0].ended == t1)
    #expect(entries[0].transcript == "/t/a.jsonl")
  }

  @Test func aLinkedTabStillRunningClaudeIsLiveAndStartedWhenItsTranscriptBegan() {
    let facts = ["a": LinkOnlyFacts(running: true, started: t0, lastActive: t1)]
    let entries = BoardEntries.merge(trees: [], links: [link("a", surfaceA, cwd: "/tmp/notes")], waiting: [], linkOnly: facts)
    #expect(entries[0].live)
    #expect(entries[0].place == .studio(surface: surfaceA))
    #expect(entries[0].started == t0)
    #expect(entries[0].ended == nil)
  }

  @Test func factsAboutALedgerSessionChangeNothing() {
    let facts = ["a": LinkOnlyFacts(running: false, started: t1, lastActive: t1)]
    let entries = BoardEntries.merge(trees: [tree([session("a", terminal: "studio:x")], live: ["a"])],
                                     links: [link("a", surfaceA)], waiting: [], linkOnly: facts)
    #expect(entries[0].live)
    #expect(entries[0].started == t0)
  }

  @Test func onlyLinksTheLedgerDoesNotKnowAreLinkOnly() {
    let trees = [tree([session("a")], live: ["a"])]
    let known = link("a", surfaceA), unknown = link("b", surfaceB, cwd: "/tmp/notes")
    #expect(BoardEntries.linkOnly(trees: trees, links: [known, unknown]) == [unknown])
  }

  @Test func anEndedLinkedTabSitsAmongTheDoneSessionsByWhenItLastWorked() {
    let facts = ["b": LinkOnlyFacts(running: false, started: t0, lastActive: t1)]
    let trees = [tree([session("a", ended: t0)], live: [])]
    let entries = BoardEntries.merge(trees: trees, links: [link("b", surfaceB, cwd: "/tmp/notes")], waiting: [], linkOnly: facts)
    #expect(entries.map(\.id) == ["b", "a"])
  }

  @Test func aSessionTheLedgerSaysEndedStaysEndedThoughALinkLingers() {
    let entries = BoardEntries.merge(trees: [tree([session("a", ended: t1)], live: [])], links: [link("a", surfaceA)], waiting: [])
    #expect(!entries[0].live)
    #expect(entries[0].ended == t1)
  }

  @Test func aCrashLeavesNoEndTimeButIsNotLive() {
    let entries = BoardEntries.merge(trees: [tree([session("a")], live: [])], links: [], waiting: [])
    #expect(!entries[0].live)
    #expect(entries[0].ended == t0)
  }

  @Test func aRemovedWorktreesSessionsStay() {
    let gone = session("old", worktree: "/r/removed", ended: t1)
    let entries = BoardEntries.merge(trees: [tree([], live: [], orphans: [gone])], links: [], waiting: [])
    #expect(entries.map(\.id) == ["old"])
    #expect(entries[0].worktree == "/r/removed")
    #expect(entries[0].project == "acme")
  }

  @Test func onlyTheNewestEndedSessionsAreKept() {
    let many = (0..<(BoardEntries.doneKept + 5)).map { i in
      TrackedSession(id: "s\(i)", worktree: "/r/wt", branch: nil, pid: nil, terminal: nil, task: nil,
                     started: Date(timeIntervalSince1970: Double(i)), ended: Date(timeIntervalSince1970: Double(i) + 1))
    }
    let live = session("live")
    let entries = BoardEntries.merge(trees: [tree(many + [live], live: ["live"])], links: [], waiting: [])
    #expect(entries.contains { $0.id == "live" })
    #expect(entries.filter { !$0.live }.count == BoardEntries.doneKept)
    #expect(!entries.contains { $0.id == "s0" })
  }

  @Test func theTranscriptIsFoundFromTheSessionsFolder() {
    let found = BoardEntries.transcript(session: "abc", folders: ["/gone", "/Users/me/Code/a b"], projects: "/p",
                                        exists: { $0 == "/p/-Users-me-Code-a-b/abc.jsonl" })
    #expect(found == "/p/-Users-me-Code-a-b/abc.jsonl")
    #expect(BoardEntries.transcript(session: "abc", folders: ["/gone"], projects: "/p", exists: { _ in false }) == nil)
  }

  @Test func resumeUsesAFolderThatHoldsTheTranscript() {
    // Claude only finds a session from the folder it started in.
    let exists: (String) -> Bool = { ["/p/-r-wt/abc.jsonl", "/r/wt"].contains($0) }
    #expect(SessionResume.folder(session: "abc", candidates: ["/r/other", "/r/wt"], projects: "/p", exists: exists) == "/r/wt")
    // The transcript's folder is gone from disk: nothing can resume it.
    #expect(SessionResume.folder(session: "abc", candidates: ["/r/gone"], projects: "/p",
                                 exists: { $0 == "/p/-r-gone/abc.jsonl" }) == nil)
    #expect(SessionResume.folder(session: "not a uuid; rm", candidates: ["/r/wt"], projects: "/p", exists: { _ in true }) == nil)
  }

  @Test func branchesEveryRepositoryHasHaveNoPRToLookUp() {
    #expect(BoardEntries.wantsPR(branch: "feat/x"))
    #expect(!BoardEntries.wantsPR(branch: "main"))
    #expect(!BoardEntries.wantsPR(branch: nil))
    #expect(!BoardEntries.wantsPR(branch: "-rf"))
  }

  @Test func aReplyTriesTheSplitThatIsWaitingFirstThenTheCardsOwnThenTheRest() {
    let surfaceC = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
    let links = [link("a", surfaceA), link("a", surfaceB), link("a", surfaceC), link("other", UUID())]
    #expect(BoardEntries.targets(session: "a", links: links, waiting: [surfaceC], preferred: surfaceB)
      == [surfaceC, surfaceB, surfaceA])
    #expect(BoardEntries.targets(session: "a", links: links, waiting: [], preferred: surfaceB) == [surfaceB, surfaceA, surfaceC])
    #expect(BoardEntries.targets(session: "a", links: links, waiting: [], preferred: nil) == [surfaceA, surfaceB, surfaceC])
  }

  @Test func aSplitThatNoLongerRunsTheSessionIsNeverATarget() {
    // The card's split was /cleared into another session: only links to this session count, even for the preferred one.
    let links = [link("new", surfaceA), link("a", surfaceB)]
    #expect(BoardEntries.targets(session: "a", links: links, waiting: [surfaceA], preferred: surfaceA) == [surfaceB])
    #expect(BoardEntries.targets(session: "gone", links: links, waiting: [], preferred: surfaceA).isEmpty)
  }
}
