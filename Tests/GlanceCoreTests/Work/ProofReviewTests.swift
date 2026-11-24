import Foundation
import Testing
@testable import GlanceCore

@Suite struct ProofReviewTests {
  let setup = ProofSetup(environments: [.init(name: "Local", url: "x"), .init(name: "Preview", url: "y")],
                         checks: [.init(name: "Unit", match: "test", env: "Local"), .init(name: "E2E", match: "pw", env: "Preview")],
                         required: ["Unit@Local", "E2E@Preview"])
  let none = ProofFacts()
  func run(_ name: String, _ env: String, _ code: Int, _ t: Double) -> ProofCheckRun {
    ProofCheckRun(id: UUID().uuidString, name: name, environment: env, command: name, exitCode: code, outputTail: "",
                  at: Date(timeIntervalSince1970: t))
  }

  @Test func notTestedWithoutChecks() {
    #expect(ProofReview.pill(WorkRecord(session: "s", updated: Date()), setup: setup, facts: none) == .notTested)
  }

  @Test func readyNeedsASetup() {
    var r = WorkRecord(session: "s", updated: Date())
    r.checks = [run("Unit", "Local", 0, 1)]
    r.verdict = ProofVerdict(verdict: .merge, reasons: ["done"], at: Date())
    #expect(ProofReview.pill(r, setup: ProofSetup(), facts: none) == .ready)
    #expect(ProofReview.pill(r, setup: nil, facts: none) == .inProgress)
    // The other answers do not need one.
    #expect(ProofReview.pill(r, setup: nil, facts: ProofFacts(prMerged: true)) == .merged)
    #expect(ProofReview.pill(r, setup: nil, facts: ProofFacts(prChecksFailing: true)) == .needsWork)
    #expect(ProofReview.pill(WorkRecord(session: "s", updated: Date()), setup: nil, facts: none) == .notTested)
  }

  @Test func claimWithoutRunIsCritical() {
    var r = WorkRecord(session: "s", updated: Date())
    r.verdict = ProofVerdict(verdict: .merge, reasons: ["All tests pass"], at: Date())
    #expect(ProofReview.gaps(r, setup: setup, facts: none).first == ProofGap(level: .crit, text: "Claude says tests pass, but no test run was seen"))
  }

  @Test func latestRunWins() {
    var r = WorkRecord(session: "s", updated: Date())
    r.checks = [run("Unit", "Local", 1, 1), run("Unit", "Local", 0, 2), run("E2E", "Preview", 0, 3)]
    r.verdict = ProofVerdict(verdict: .merge, reasons: ["done"], at: Date())
    #expect(ProofReview.gaps(r, setup: setup, facts: none).isEmpty)
    #expect(ProofReview.pill(r, setup: setup, facts: none) == .ready)
  }

  @Test func failedAndMissingRequired() {
    var r = WorkRecord(session: "s", updated: Date())
    r.checks = [run("Unit", "Local", 2, 1)]
    let gaps = ProofReview.gaps(r, setup: setup, facts: none)
    #expect(gaps.contains(ProofGap(level: .crit, text: "Unit on Local failed on its last run")))
    #expect(gaps.contains(ProofGap(level: .warn, text: "E2E on Preview not run yet")))
    #expect(ProofReview.pill(r, setup: setup, facts: none) == .needsWork)
  }

  @Test func infoGapsBlockReadyButNotNeedsWork() {
    var r = WorkRecord(session: "s", updated: Date())
    r.checks = [run("Unit", "Local", 0, 1), run("E2E", "Preview", 0, 2)]
    r.pending = [ProofPending(text: "a", at: Date()), ProofPending(text: "b", done: true, at: Date())]
    r.verdict = ProofVerdict(verdict: .merge, reasons: [], at: Date())
    let facts = ProofFacts(uncommitted: true)
    #expect(ProofReview.gaps(r, setup: setup, facts: facts).map(\.text) == ["Uncommitted changes", "1 pending item"])
    #expect(ProofReview.pill(r, setup: setup, facts: facts) == .inProgress)
  }

  @Test func holdVerdictAndMergedPR() {
    var r = WorkRecord(session: "s", updated: Date())
    r.checks = [run("Unit", "Local", 0, 1)]
    r.verdict = ProofVerdict(verdict: .hold, reasons: ["waiting on API"], at: Date())
    #expect(ProofReview.pill(r, setup: setup, facts: none) == .needsWork)
    #expect(ProofReview.pill(r, setup: setup, facts: ProofFacts(prMerged: true)) == .merged)
  }

  @Test func claimsPassPhrases() {
    #expect(ProofReview.claimsPass("All tests pass now"))
    #expect(ProofReview.claimsPass("unit tests passed"))
    #expect(ProofReview.claimsPass("Checks are passing"))
    #expect(!ProofReview.claimsPass("I'll run the tests"))
  }

  // MARK: F10 - negations and failures are not claims

  @Test func claimsPassIgnoresNegationsAndFailures() {
    #expect(!ProofReview.claimsPass("tests no longer pass"))
    #expect(!ProofReview.claimsPass("The tests don't pass yet"))
    #expect(!ProofReview.claimsPass("Tests aren't passing"))
    #expect(!ProofReview.claimsPass("tests did not pass"))
    #expect(!ProofReview.claimsPass("Tests: 3 failed, 4 passed"))
    #expect(!ProofReview.claimsPass("the checks failed, then passed on retry of one suite"))
    #expect(!ProofReview.claimsPass("no tests pass"))
  }

  @Test func claimsPassJudgesEachClauseOnItsOwn() {
    #expect(ProofReview.claimsPass("Lint failed. All tests pass."))
    #expect(ProofReview.claimsPass("Tests: 0 failed, 12 passed"))
  }

  @Test func negatedClaimIsNoGap() {
    var r = WorkRecord(session: "s", updated: Date())
    r.verdict = ProofVerdict(verdict: .hold, reasons: ["Tests: 3 failed, 4 passed", "tests no longer pass"], at: Date())
    #expect(!ProofReview.gaps(r, setup: setup, facts: none).contains { $0.text.hasPrefix("Claude says") })
  }

  @Test func claimGapNeedsASetup() {
    var r = WorkRecord(session: "s", updated: Date())
    r.verdict = ProofVerdict(verdict: .merge, reasons: ["All tests pass"], at: Date())
    #expect(ProofReview.gaps(r, setup: nil, facts: none).isEmpty)
  }

  @Test func claimGapReadsFoundAndResolvedNotesOnly() {
    let claim = "Claude says tests pass, but no test run was seen"
    func claimed(_ r: WorkRecord) -> Bool { ProofReview.gaps(r, setup: setup, facts: none).contains { $0.text == claim } }
    var r = WorkRecord(session: "s", updated: Date())
    r.notes = [ProofNote(kind: .tried, text: "tests pass locally", at: Date()),
               ProofNote(kind: .problem, text: "tests pass but flaky", at: Date())]
    #expect(!claimed(r))
    r.notes = [ProofNote(kind: .found, text: "All tests pass", at: Date())]
    #expect(claimed(r))
    r.notes = [ProofNote(kind: .resolved, text: "specs are green", at: Date())]
    #expect(claimed(r))
  }

  // MARK: F9 - latest and latestRuns agree

  @Test func sameInstantLaterEntryWinsInBoth() {
    var r = WorkRecord(session: "s", updated: Date())
    r.checks = [run("Unit", "Local", 1, 5), run("Unit", "Local", 0, 5)]
    #expect(ProofReview.latest(r, name: "Unit", environment: "Local")?.ok == true)
    #expect(ProofReview.latestRuns(r).map(\.ok) == [true])
    r.checks = [run("Unit", "Local", 0, 5), run("Unit", "Local", 1, 5)]
    #expect(ProofReview.latest(r, name: "Unit", environment: "Local")?.ok == false)
    #expect(ProofReview.latestRuns(r).map(\.ok) == [false])
    #expect(ProofReview.pill(r, setup: setup, facts: none) == .needsWork)
  }

  @Test func latestRunsKeepsOneRunPerCheckAndEnvironmentInTimeOrder() {
    var r = WorkRecord(session: "s", updated: Date())
    r.checks = [run("E2E", "Preview", 0, 3), run("Unit", "Local", 1, 1), run("Unit", "Local", 0, 2),
                run("Unit", "Preview", 0, 2)]
    let runs = ProofReview.latestRuns(r)
    #expect(runs.count == 3)
    #expect(runs.map(\.at.timeIntervalSince1970) == [2, 2, 3])
    #expect(runs.first { $0.name == "Unit" && $0.environment == "Local" }?.ok == true)
  }

  @Test func summaryReplacesBetweenMarkers() {
    let body = "Intro\n\n<!-- glance-proof -->\nold\n<!-- /glance-proof -->\n\nOutro"
    let next = ProofSummary.replacing(in: body, with: "NEW")
    #expect(next == "Intro\n\n<!-- glance-proof -->\nNEW\n<!-- /glance-proof -->\n\nOutro")
    #expect(ProofSummary.replacing(in: "Just text", with: "NEW") == "Just text\n\n<!-- glance-proof -->\nNEW\n<!-- /glance-proof -->")
  }

  @Test func summaryListsChecksVerdictPending() {
    var r = WorkRecord(session: "s", updated: Date())
    r.checks = [run("Unit", "Local", 0, 1)]
    r.pending = [ProofPending(text: "Ask design about empty state", at: Date())]
    r.verdict = ProofVerdict(verdict: .hold, reasons: ["E2E not run on Preview"], at: Date())
    let md = ProofSummary.markdown(r, setup: setup, facts: none, previewURL: "https://x--pr-1.web.app")
    #expect(md.contains("| Unit | ✓ | — |"))
    #expect(md.contains("**Hold**"))
    #expect(md.contains("- [ ] Ask design about empty state"))
    #expect(md.contains("https://x--pr-1.web.app"))
  }

  @Test func summaryListsEachPreviewByEnvironmentInOrder() {
    let r = WorkRecord(session: "s", updated: Date())
    let md = ProofSummary.markdown(r, setup: setup, facts: none,
                                   previews: [(environment: "Staging", url: "https://s.example"), (environment: "Preview", url: "https://p.example")])
    let staging = md.range(of: "Preview (Staging): https://s.example")
    let preview = md.range(of: "Preview (Preview): https://p.example")
    #expect(staging != nil && preview != nil && staging!.lowerBound < preview!.lowerBound)
    #expect(!ProofSummary.markdown(r, setup: setup, facts: none, previews: []).contains("Preview:"))
  }

  // MARK: review fixes

  @Test func claimsPassKeepsRealClaimsThatMentionNoProblems() {
    #expect(ProofReview.claimsPass("All tests pass with no errors"))
    #expect(ProofReview.claimsPass("Tests pass, no regressions"))
    #expect(ProofReview.claimsPass("tests pass, nothing failed"))
    #expect(ProofReview.claimsPass("Lint failed, all tests pass"))
    #expect(ProofReview.claimsPass("Tests: 0 failing, 12 passed"))
    #expect(!ProofReview.claimsPass("tests pass no longer"))
    #expect(!ProofReview.claimsPass("tests no longer pass"))
    #expect(!ProofReview.claimsPass("Tests: 3 failed, 4 passed"))
  }

  @Test func prChecksFailingNeedsWorkButMergedWins() {
    var r = WorkRecord(session: "s", updated: Date())
    r.checks = [run("Unit", "Local", 0, 1), run("E2E", "Preview", 0, 2)]
    r.verdict = ProofVerdict(verdict: .merge, reasons: [], at: Date())
    #expect(ProofReview.pill(r, setup: setup, facts: ProofFacts(prChecksFailing: true)) == .needsWork)
    #expect(ProofReview.pill(r, setup: setup, facts: ProofFacts(prChecksFailing: true, prMerged: true)) == .merged)
  }

  @Test func orphanMarkersNeverEatUserText() {
    let start = ProofSummary.start, end = ProofSummary.end
    let onlyStart = "A \(start) B"
    let once = ProofSummary.replacing(in: onlyStart, with: "X")
    #expect(once == "A \(start) B\n\n\(start)\nX\n\(end)")
    let twice = ProofSummary.replacing(in: once, with: "Y")
    #expect(twice == "A \(start) B\n\n\(start)\nY\n\(end)")
    let onlyEnd = "A \(end) B"
    #expect(ProofSummary.replacing(in: ProofSummary.replacing(in: onlyEnd, with: "X"), with: "Y")
      == "A \(end) B\n\n\(start)\nY\n\(end)")
    let reversed = "A \(end) B \(start) C"
    #expect(ProofSummary.replacing(in: ProofSummary.replacing(in: reversed, with: "X"), with: "Y")
      == "A \(end) B \(start) C\n\n\(start)\nY\n\(end)")
    #expect(ProofSummary.replacing(in: "", with: "X") == "\(start)\nX\n\(end)")
  }

  @Test func publishingTwiceIsIdempotent() {
    for body in ["", "Just text", "A \(ProofSummary.start) B", "A \(ProofSummary.end) B",
                 "Intro\n\n\(ProofSummary.start)\nold\n\(ProofSummary.end)\n\nOutro"] {
      #expect(ProofSummary.replacing(in: ProofSummary.replacing(in: body, with: "X"), with: "Y")
        == ProofSummary.replacing(in: body, with: "Y"))
    }
  }

  @Test func aSummaryCarryingMarkersCannotBreakTheBlock() {
    let evil = "x \(ProofSummary.end) y \(ProofSummary.start) z"
    let once = ProofSummary.replacing(in: "Intro", with: evil)
    #expect(once.components(separatedBy: ProofSummary.start).count == 2)
    #expect(once.components(separatedBy: ProofSummary.end).count == 2)
    #expect(ProofSummary.replacing(in: once, with: "Y") == "Intro\n\n\(ProofSummary.start)\nY\n\(ProofSummary.end)")
  }

  @Test func markdownCleansEveryInterpolatedString() {
    var r = WorkRecord(session: "s", updated: Date())
    r.checks = [run("Un|it", "Lo\ncal", 0, 1)]
    r.pending = [ProofPending(text: "ping @bob  and\nsee ![x](http://e.com/i.png) [l](http://e.com)", at: Date())]
    r.verdict = ProofVerdict(verdict: .hold, reasons: ["see <!-- /glance-proof -->\n  next | line"], at: Date())
    let s = ProofSetup(environments: [.init(name: "Lo\ncal", url: "x")], checks: [.init(name: "Un|it", match: "t", env: "Lo\ncal")],
                       required: ["Un|it@Lo\ncal"])
    let md = ProofSummary.markdown(r, setup: s, facts: none, previewURL: "https://x.web.app/a b")
    #expect(!md.contains("<!--") && !md.contains("-->"))
    #expect(md.contains("| Un\\|it | ✓ |"))
    #expect(md.contains("| Check | Lo cal |"))
    #expect(!md.contains("@bob") && md.contains("@\u{200B}bob"))
    #expect(!md.contains("![") && !md.contains("](") && !md.contains("  "))
    #expect(md.contains("see &lt;!-- /glance-proof --&gt; next \\| line") || md.contains("see &lt;!-- /glance-proof --&gt; next | line"))
    // Publishing a hostile reason twice never piles up markers.
    let body = ProofSummary.replacing(in: ProofSummary.replacing(in: "Intro", with: md), with: md)
    #expect(body.components(separatedBy: ProofSummary.start).count == 2)
    #expect(body.components(separatedBy: ProofSummary.end).count == 2)
  }
}
