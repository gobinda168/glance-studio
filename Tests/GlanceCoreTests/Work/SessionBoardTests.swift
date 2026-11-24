import Foundation
import Testing
@testable import GlanceCore

@Suite struct SessionBoardTests {
  let now = Date(timeIntervalSince1970: 1_000)

  func card(_ id: String = "s", state: BoardState = .idle(since: nil), pill: ProofPill = .inProgress,
            gaps: [ProofGap] = [], merged: Bool = false, activity: Double = 0) -> BoardCard {
    BoardCard(id: id, title: id, project: "acme", place: .external("Warp"), state: state, pill: pill, gaps: gaps,
              pr: merged ? BoardPR(number: 1, merged: true, checks: .passing) : nil,
              activity: Date(timeIntervalSince1970: activity))
  }
  let tool = RunningTool(id: "t", name: "Bash", detail: "npm test", since: nil)
  let crit = ProofGap(level: .crit, text: "PR checks failing")

  @Test func aSessionWaitingOnTheUserNeedsThem() {
    #expect(SessionBoard.lane(card(state: .waiting(title: "Edit?"))) == .needsYou)
    // Even on a merged PR: a prompt must never hide in Done.
    #expect(SessionBoard.lane(card(state: .waiting(title: "Edit?"), merged: true)) == .needsYou)
  }

  @Test func workThatFailedNeedsTheUserEvenWhileClaudeWorks() {
    #expect(SessionBoard.lane(card(state: .thinking, pill: .needsWork)) == .needsYou)
    #expect(SessionBoard.lane(card(pill: .inProgress, gaps: [crit])) == .needsYou)
    // A warning is not a critical gap.
    #expect(SessionBoard.lane(card(state: .thinking, gaps: [ProofGap(level: .warn, text: "x")])) == .working)
  }

  @Test func runningAndThinkingAreWorking() {
    #expect(SessionBoard.lane(card(state: .thinking)) == .working)
    #expect(SessionBoard.lane(card(state: .tool(tool))) == .working)
    #expect(SessionBoard.lane(card(state: .tool(tool), merged: true)) == .working)
  }

  @Test func idleIsReadyOnlyWhenTheProofSaysSo() {
    #expect(SessionBoard.lane(card(pill: .ready)) == .ready)
    #expect(SessionBoard.lane(card(pill: .inProgress)) == .done)
    #expect(SessionBoard.lane(card(pill: .notTested)) == .done)
  }

  @Test func endedAndMergedAreDone() {
    #expect(SessionBoard.lane(card(state: .ended(at: now), pill: .needsWork)) == .done)
    #expect(SessionBoard.lane(card(pill: .merged, merged: true)) == .done)
  }

  @Test func theMostUrgentComesFirstThenTheMostRecent() {
    let cards = [card("old", pill: .needsWork, activity: 1), card("new", pill: .needsWork, activity: 9),
                 card("gap", gaps: [crit], activity: 99), card("wait", state: .waiting(title: "?"), activity: 0)]
    #expect(SessionBoard.ordered(cards, in: .needsYou).map(\.id) == ["wait", "new", "old", "gap"])
    // Equal times keep a stable order, so cards don't swap on every refresh.
    let tied = [card("b", pill: .ready), card("a", pill: .ready)]
    #expect(SessionBoard.ordered(tied, in: .ready).map(\.id) == ["a", "b"])
  }

  @Test func theHeaderCounts() {
    var failing = card("f", state: .thinking)
    failing.failing = true
    let counts = SessionBoard.counts([card("w", state: .waiting(title: "?")), failing, card("r", pill: .ready)])
    #expect(counts == BoardCounts(needsYou: 1, working: 1, ready: 1, failing: 1))
  }

  @Test func dotsFollowTheSetupThenTheRecord() {
    var record = WorkRecord(session: "s", updated: now)
    record.checks = [ProofCheckRun(id: "1", name: "Unit", environment: "Local", command: "t", exitCode: 0, outputTail: "", at: now),
                     ProofCheckRun(id: "2", name: "E2E", environment: "Local", command: "p", exitCode: 1, outputTail: "", at: now)]
    let setup = ProofSetup(environments: [.init(name: "Local", url: "x"), .init(name: "Preview", url: "y")],
                           checks: [.init(name: "Unit", match: "t", env: "Local"), .init(name: "E2E", match: "p", env: "Local")],
                           required: [])
    let dots = SessionBoard.dots(record: record, setup: setup)
    #expect(dots.map(\.environment) == ["Local", "Preview"])
    #expect(dots[0].checks.map(\.result) == [.passed, .failed])
    #expect(dots[1].checks.map(\.result) == [.notRun, .notRun])
    // No setup: what the record ran, by name.
    #expect(SessionBoard.dots(record: record, setup: nil).map(\.environment) == ["Local"])
    // No checks at all: no row of empty dots.
    #expect(SessionBoard.dots(record: WorkRecord(session: "s", updated: now), setup: nil).isEmpty)
  }

  @Test func theLiveStateComesFromThePromptThenTheTranscript() {
    let working = SessionLive(working: true, tool: nil, lastActivity: now)
    #expect(SessionBoard.state(live: working, waitingTitle: "Edit?", ended: nil) == .waiting(title: "Edit?"))
    #expect(SessionBoard.state(live: working, waitingTitle: nil, ended: nil) == .thinking)
    #expect(SessionBoard.state(live: SessionLive(working: true, tool: tool, lastActivity: now), waitingTitle: nil, ended: nil) == .tool(tool))
    #expect(SessionBoard.state(live: SessionLive(working: false, tool: nil, lastActivity: now), waitingTitle: nil, ended: nil) == .idle(since: now))
    #expect(SessionBoard.state(live: nil, waitingTitle: nil, ended: now) == .ended(at: now))
    // A session that ended has no live prompt.
    #expect(SessionBoard.state(live: working, waitingTitle: "Edit?", ended: now) == .ended(at: now))
  }
}
