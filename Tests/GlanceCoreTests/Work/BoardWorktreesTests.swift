import Foundation
import Testing
@testable import GlanceCore

@Suite struct BoardWorktreesTests {
  let t = { (s: Double) in Date(timeIntervalSince1970: s) }

  func session(_ id: String, _ worktree: String, ended: Double?) -> TrackedSession {
    TrackedSession(id: id, worktree: worktree, branch: "feat/\(id)", pid: nil, terminal: nil, task: nil, started: t(1), ended: ended.map(t))
  }
  func info(_ path: String, isMain: Bool = false, sessions: [TrackedSession] = [], live: Set<String> = []) -> WorktreeInfo {
    WorktreeInfo(path: path, branch: "b", isMain: isMain, files: [], sessions: sessions, live: live, merged: false,
                 tooMany: false, warning: false, added: 0, removed: 0)
  }

  @Test func liveWorktreesComeFirstThenClosedByAge() {
    let tree = RepoTree(repo: "/r/.git", name: "acme", main: "/r", worktrees: [
      info("/r/old", sessions: [session("o", "/r/old", ended: 10)]),
      info("/r/new", sessions: [session("n", "/r/new", ended: 50)]),
      info("/r/run", sessions: [session("x", "/r/run", ended: nil)], live: ["x"]),
    ])
    let rows = BoardWorktrees.rows(trees: [tree])
    #expect(rows.map(\.path) == ["/r/run", "/r/new", "/r/old"])
    #expect(rows[0].live)
    #expect(rows[1].lastActive == t(50))
  }

  @Test func theMainCheckoutIsListedOnlyWhileASessionIsLiveInIt() {
    let idle = RepoTree(repo: "/r/.git", name: "a", main: "/r", worktrees: [info("/r", isMain: true, sessions: [session("m", "/r", ended: 5)])])
    #expect(BoardWorktrees.rows(trees: [idle]).isEmpty)
    let live = RepoTree(repo: "/r/.git", name: "a", main: "/r", worktrees: [info("/r", isMain: true, sessions: [session("m", "/r", ended: nil)], live: ["m"])])
    #expect(BoardWorktrees.rows(trees: [live]).map(\.path) == ["/r"])
  }

  @Test func aRemovedWorktreeStaysClosedWithItsBranch() {
    let tree = RepoTree(repo: "/r/.git", name: "a", main: "/r", worktrees: [],
                        orphans: [session("a", "/r/gone", ended: 20), session("b", "/r/gone", ended: 30)])
    let rows = BoardWorktrees.rows(trees: [tree])
    #expect(rows.count == 1)
    #expect(!rows[0].exists)
    #expect(rows[0].lastActive == t(30))
    #expect(rows[0].branch == "feat/b")
    #expect(rows[0].sessions == ["b", "a"])
  }

  @Test func aWorktreeThatNeverRanASessionIsClosedWithNoAge() {
    let tree = RepoTree(repo: "/r/.git", name: "a", main: "/r", worktrees: [info("/r/fresh")])
    let rows = BoardWorktrees.rows(trees: [tree])
    #expect(rows.map(\.path) == ["/r/fresh"])
    #expect(rows[0].lastActive == nil)
  }

  func card(dots: [BoardEnvironmentDots] = [], failing: Bool = false) -> BoardCard {
    BoardCard(id: "s", title: "t", project: "p", place: .nowhere, state: .ended(at: nil), pill: .notTested, dots: dots,
              failing: failing, activity: t(1))
  }
  func dots(_ results: BoardCheckDot.Result...) -> [BoardEnvironmentDots] {
    [BoardEnvironmentDots(environment: "local", checks: results.enumerated().map { BoardCheckDot(name: "c\($0.offset)", result: $0.element) })]
  }

  @Test func aClosedWorktreeShowsPassedOnlyWhenEveryCheckPassed() {
    #expect(BoardWorktrees.outcome(of: card(dots: dots(.passed, .passed))) == .passed)
  }

  @Test func aFailedRunShowsFailedWhateverElsePassed() {
    #expect(BoardWorktrees.outcome(of: card(dots: dots(.passed, .failed))) == .failed)
    #expect(BoardWorktrees.outcome(of: card(failing: true)) == .failed)
  }

  @Test func noProofOrPartialProofShowsNothing() {
    #expect(BoardWorktrees.outcome(of: nil) == .none)
    #expect(BoardWorktrees.outcome(of: card()) == .none)
    #expect(BoardWorktrees.outcome(of: card(dots: dots(.notRun, .notRun))) == .none)
    #expect(BoardWorktrees.outcome(of: card(dots: dots(.passed, .notRun))) == .none)
  }

  @Test func aPathMatchesItsTrailingSlashAndTheSymlinkedTmp() {
    #expect(BoardWorktrees.key("/r/wt/") == BoardWorktrees.key("/r/wt"))
    #expect(BoardWorktrees.key("/private/tmp/a") == BoardWorktrees.key("/tmp/a"))
    #expect(BoardWorktrees.key("/private/var/folders/x") == BoardWorktrees.key("/var/folders/x"))
    #expect(BoardWorktrees.key("/r//wt/./sub/..") == BoardWorktrees.key("/r/wt"))
  }

  @Test func differentFoldersStayDifferent() {
    #expect(BoardWorktrees.key("/r/wt") != BoardWorktrees.key("/r/wt2"))
    #expect(BoardWorktrees.key("/private/other") != BoardWorktrees.key("/other"))
    #expect(BoardWorktrees.key("/tmp") != BoardWorktrees.key("/tmpx"))
  }

  @Test func aFilterWhoseProjectHasNoSessionsIsDropped() {
    let cards = [card()]
    #expect(SessionBoard.keeping(filter: "p", in: cards) == "p")
    #expect(SessionBoard.keeping(filter: "gone", in: cards) == nil)
    #expect(SessionBoard.keeping(filter: nil, in: cards) == nil)
  }
}
