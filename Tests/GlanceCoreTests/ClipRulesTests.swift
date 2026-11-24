import Foundation
import Testing
@testable import GlanceCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)
private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

private let page = "https://example.com/app"

private extension ClipRules {
  /// A rules value with Claude working (a tool started at 0 s) and `target` open on `url`.
  static func working(_ target: String = "A", url: String = page) -> ClipRules {
    var rules = ClipRules()
    _ = rules.step(.tool(phase: .start, at: at(0)))
    _ = rules.step(.pageOpened(target: target, url: url, adopted: false, at: at(0)))
    return rules
  }

  mutating func frames(_ target: String, _ count: Int, from seconds: Double = 1) {
    for n in 0..<count { _ = step(.frame(target: target, at: at(seconds + Double(n) * 0.05))) }
  }
}

private func finish(_ target: String, _ keep: Bool, _ seconds: Double) -> ClipRules.Output {
  .finish(target: target, keep: keep, endedAt: at(seconds))
}

@Test func aToolStartWithARecordablePageStartsAClip() {
  var rules = ClipRules()
  #expect(rules.step(.pageOpened(target: "A", url: page, adopted: false, at: at(0))) == [])
  #expect(rules.step(.tool(phase: .start, at: at(1))) == [.start(target: "A", url: page)])
}

@Test func aToolInFlightForAMinuteIsNotIdle() {
  var rules = ClipRules.working()
  #expect(rules.step(.tick(at: at(60))) == [])
  #expect(rules.step(.tick(at: at(120))) == [])
}

@Test func fiveSecondsAfterTheLastToolEndFinishesAndFourPointNineDoesNot() {
  var rules = ClipRules.working()
  rules.frames("A", 5)
  #expect(rules.step(.tool(phase: .end, at: at(10))) == [])
  #expect(rules.step(.tick(at: at(14.9))) == [])
  #expect(rules.step(.tick(at: at(15))) == [finish("A", true, 15)])
  #expect(rules.step(.tick(at: at(30))) == [])
}

@Test func anIdleFinishEndsAtTheLastToolEndPlusFiveEvenWhenTheTickIsLate() {
  var rules = ClipRules.working()
  rules.frames("A", 5)
  _ = rules.step(.tool(phase: .end, at: at(10)))
  #expect(rules.step(.tick(at: at(40))) == [finish("A", true, 15)])
}

@Test func aNewToolBeforeTheIdleTimeKeepsTheClipGoing() {
  var rules = ClipRules.working()
  rules.frames("A", 3)
  _ = rules.step(.tool(phase: .end, at: at(10)))
  #expect(rules.step(.tool(phase: .start, at: at(13))) == [])
  _ = rules.step(.tool(phase: .end, at: at(14)))
  #expect(rules.step(.tick(at: at(18.9))) == [])
  #expect(rules.step(.tick(at: at(19))) == [finish("A", true, 19)])
}

@Test func twoOverlappingToolCallsKeepTheClipUntilBothHaveEnded() {
  var rules = ClipRules.working()
  rules.frames("A", 3)
  #expect(rules.step(.tool(phase: .start, at: at(1))) == [])
  _ = rules.step(.tool(phase: .end, at: at(2)))
  #expect(rules.step(.tick(at: at(20))) == [])
  _ = rules.step(.tool(phase: .end, at: at(21)))
  #expect(rules.step(.tick(at: at(25.9))) == [])
  #expect(rules.step(.tick(at: at(26))) == [finish("A", true, 26)])
}

@Test func navigatingAwayFinishesTheClipAndStartsANewOneInTheSameStep() {
  var rules = ClipRules.working()
  rules.frames("A", 3)
  let next = "https://example.com/other"
  #expect(rules.step(.navigated(target: "A", url: next, at: at(5)))
    == [finish("A", true, 5), .start(target: "A", url: next)])
}

@Test func aFragmentChangeIsTheSameVisit() {
  var rules = ClipRules.working()
  #expect(rules.step(.navigated(target: "A", url: page + "#pricing", at: at(5))) == [])
  #expect(ClipRules.sameVisit(page, page + "#a"))
  #expect(ClipRules.sameVisit(page + "#a", page + "#b"))
  #expect(!ClipRules.sameVisit(page, page + "/x"))
  #expect(!ClipRules.sameVisit(page + "?q=1", page + "?q=2#a"))
}

@Test func onlyHTTPHTTPSAndFileAreRecordable() {
  for url in ["http://localhost:3000", "https://example.com", "HTTPS://Example.com/", "file:///Users/me/index.html"] {
    #expect(ClipRules.recordable(url), "\(url)")
  }
  for url in ["about:blank", "", "chrome://newtab", "data:text/html,hi", "ftp://x/y", "javascript:alert(1)", "https://", "file://", "view-source:https://a.b"] {
    #expect(!ClipRules.recordable(url), "\(url)")
  }
}

@Test func aBlankPageDoesNotStartAClip() {
  var rules = ClipRules()
  _ = rules.step(.tool(phase: .start, at: at(0)))
  #expect(rules.step(.pageOpened(target: "A", url: "about:blank", adopted: false, at: at(0))) == [])
}

@Test func theUsualFirstCaseStartsWhenThePageNavigatesAwayFromBlank() {
  var rules = ClipRules()
  #expect(rules.step(.tool(phase: .start, at: at(0))) == [])
  #expect(rules.step(.pageOpened(target: "A", url: "about:blank", adopted: false, at: at(0.1))) == [])
  #expect(rules.step(.navigated(target: "A", url: page, at: at(0.5))) == [.start(target: "A", url: page)])
}

@Test func aRecordablePageOpenedWhileActiveStartsAClip() {
  var rules = ClipRules()
  _ = rules.step(.tool(phase: .start, at: at(0)))
  #expect(rules.step(.pageOpened(target: "A", url: page, adopted: false, at: at(1))) == [.start(target: "A", url: page)])
}

@Test func aPageOpenedWhileIdleWaitsForTheNextToolStart() {
  var rules = ClipRules()
  #expect(rules.step(.pageOpened(target: "A", url: page, adopted: false, at: at(0))) == [])
  _ = rules.step(.tool(phase: .start, at: at(1)))
  _ = rules.step(.tool(phase: .end, at: at(2)))
  _ = rules.step(.tick(at: at(8)))
  // Idle again: a page opened now waits.
  #expect(rules.step(.pageOpened(target: "B", url: page + "/b", adopted: false, at: at(9))) == [])
  #expect(rules.step(.tool(phase: .start, at: at(10))) == [.start(target: "A", url: page), .start(target: "B", url: page + "/b")])
}

@Test func navigatingWhileIdleRemembersTheURLForTheNextToolStart() {
  var rules = ClipRules()
  _ = rules.step(.pageOpened(target: "A", url: "about:blank", adopted: false, at: at(0)))
  #expect(rules.step(.navigated(target: "A", url: page, at: at(1))) == [])
  #expect(rules.step(.tool(phase: .start, at: at(2))) == [.start(target: "A", url: page)])
}

// MARK: Events that arrive in the other order

@Test func aNavigationThatBeatsItsPageAnnouncementIsNotLost() {
  var rules = ClipRules()
  #expect(rules.step(.navigated(target: "A", url: page, at: at(1))) == [])
  #expect(rules.step(.pageOpened(target: "A", url: "about:blank", adopted: false, at: at(0.5))) == [])
  #expect(rules.step(.tool(phase: .start, at: at(2))) == [.start(target: "A", url: page)])
}

@Test func aPendingNavigationWinsOverAnOpenedURLThatIsntRecordable() {
  var rules = ClipRules()
  _ = rules.step(.navigated(target: "A", url: page, at: at(1)))
  #expect(rules.step(.pageOpened(target: "A", url: "about:blank", adopted: false, at: at(2))) == [])
  #expect(rules.step(.tool(phase: .start, at: at(3))) == [.start(target: "A", url: page)])
}

@Test func anOpenedURLNewerThanThePendingNavigationWins() {
  var rules = ClipRules()
  _ = rules.step(.navigated(target: "A", url: page + "/old", at: at(1)))
  _ = rules.step(.pageOpened(target: "A", url: page + "/new", adopted: false, at: at(2)))
  #expect(rules.step(.tool(phase: .start, at: at(3))) == [.start(target: "A", url: page + "/new")])
}

@Test func aPendingNavigationIsDroppedWhenThePageCloses() {
  var rules = ClipRules()
  _ = rules.step(.navigated(target: "A", url: page, at: at(1)))
  _ = rules.step(.pageClosed(target: "A", at: at(2)))
  _ = rules.step(.pageOpened(target: "A", url: "about:blank", adopted: false, at: at(3)))
  #expect(rules.step(.tool(phase: .start, at: at(4))) == [])
}

@Test func aPendingNavigationNeverMakesAUserPageRecordable() {
  var rules = ClipRules()
  _ = rules.step(.navigated(target: "U", url: page, at: at(1)))
  _ = rules.step(.pageOpened(target: "U", url: "about:blank", adopted: true, at: at(0.5)))
  #expect(rules.step(.tool(phase: .start, at: at(2))) == [])
}

@Test func announcingAKnownPageAgainChangesNothing() {
  var rules = ClipRules.working()
  rules.frames("A", 3)
  #expect(rules.step(.pageOpened(target: "A", url: page, adopted: false, at: at(5))) == [])
  #expect(rules.step(.pageClosed(target: "A", at: at(6))) == [finish("A", true, 6)])
}

// MARK: Adopted pages

@Test func aPageTheUserOpenedIsNeverRecorded() {
  var rules = ClipRules()
  _ = rules.step(.tool(phase: .start, at: at(0)))
  #expect(rules.step(.pageOpened(target: "U", url: page, adopted: true, at: at(0))) == [])
  #expect(rules.step(.navigated(target: "U", url: page + "/next", at: at(1))) == [])
  _ = rules.step(.tool(phase: .end, at: at(2)))
  #expect(rules.step(.tool(phase: .start, at: at(3))) == [])
}

@Test func aPageThatBecomesTheUsersEndsItsClip() {
  var rules = ClipRules.working()
  rules.frames("A", 3)
  #expect(rules.step(.pageOpened(target: "A", url: page, adopted: true, at: at(2))) == [finish("A", true, 2)])
}

// MARK: Closing, cutting, keeping

@Test func closingThePageFinishesTheClip() {
  var rules = ClipRules.working()
  rules.frames("A", 4)
  #expect(rules.step(.pageClosed(target: "A", at: at(3))) == [finish("A", true, 3)])
  #expect(rules.step(.pageClosed(target: "A", at: at(4))) == [])
  #expect(rules.step(.tool(phase: .start, at: at(5))) == [])
}

@Test func atOneHundredEightySecondsTheClipIsCutAndStaysCutUntilTheNextToolStart() {
  var rules = ClipRules.working()
  // A tool call every so often, so the call counts as alive.
  _ = rules.step(.tool(phase: .end, at: at(100)))
  _ = rules.step(.tool(phase: .start, at: at(100)))
  #expect(rules.step(.pageOpened(target: "B", url: page + "/b", adopted: false, at: at(100))) == [.start(target: "B", url: page + "/b")])
  rules.frames("A", 10)
  #expect(rules.step(.tick(at: at(179.9))) == [])
  #expect(rules.step(.tick(at: at(180))) == [finish("A", true, 180)])
  // No restart on A, not by navigating either; B (started at 100 s) goes on.
  #expect(rules.step(.navigated(target: "A", url: page + "/more", at: at(181))) == [])
  #expect(rules.step(.tick(at: at(200))) == [])
  // The next tool start records A again; B already has its clip.
  _ = rules.step(.tool(phase: .end, at: at(250)))
  #expect(rules.step(.tool(phase: .start, at: at(250))) == [.start(target: "A", url: page + "/more")])
  #expect(rules.step(.tick(at: at(280))) == [finish("B", false, 280)])
}

@Test func aClipKeepsWhenItHasAFrameAndLastedASecond() {
  // A static page: one frame for the whole visit.
  var still = ClipRules.working()
  still.frames("A", 1)
  #expect(still.step(.pageClosed(target: "A", at: at(3))) == [finish("A", true, 3)])

  var exact = ClipRules.working()
  exact.frames("A", 1)
  #expect(exact.step(.pageClosed(target: "A", at: at(ClipRules.minVisitSeconds))) == [finish("A", true, 1)])
}

@Test func aPageThatNeverPaintedIsNotKept() {
  var rules = ClipRules.working()
  #expect(rules.step(.pageClosed(target: "A", at: at(30))) == [finish("A", false, 30)])
}

@Test func aRedirectFlashIsNotKept() {
  var rules = ClipRules.working()
  rules.frames("A", 1, from: 0.1)
  let landing = "https://example.com/landing"
  #expect(rules.step(.navigated(target: "A", url: landing, at: at(0.9)))
    == [finish("A", false, 0.9), .start(target: "A", url: landing)])
}

@Test func framesForAnUnknownTargetOrAFinishedClipAreIgnored() {
  var rules = ClipRules.working()
  #expect(rules.step(.frame(target: "nope", at: at(1))) == [])
  _ = rules.step(.tool(phase: .end, at: at(2)))
  #expect(rules.step(.tick(at: at(7))) == [finish("A", false, 7)])
  rules.frames("A", 5, from: 8)
  _ = rules.step(.tool(phase: .start, at: at(10)))
  #expect(rules.step(.pageClosed(target: "A", at: at(12))) == [finish("A", false, 12)])
}

@Test func twoPagesBothRecord() {
  var rules = ClipRules()
  _ = rules.step(.tool(phase: .start, at: at(0)))
  #expect(rules.step(.pageOpened(target: "A", url: page, adopted: false, at: at(0))) == [.start(target: "A", url: page)])
  #expect(rules.step(.pageOpened(target: "B", url: page + "/b", adopted: false, at: at(0))) == [.start(target: "B", url: page + "/b")])
  rules.frames("A", 3)
  rules.frames("B", 2)
  _ = rules.step(.tool(phase: .end, at: at(2)))
  #expect(rules.step(.tick(at: at(7))) == [finish("A", true, 7), finish("B", true, 7)])
}

@Test func aToolEndWithNothingInFlightDoesNotCrashOrStartAnything() {
  var rules = ClipRules()
  #expect(rules.step(.tool(phase: .end, at: at(0))) == [])
  #expect(rules.step(.tool(phase: .end, at: at(1))) == [])
  #expect(rules.step(.pageOpened(target: "A", url: page, adopted: false, at: at(2))) == [])
  #expect(rules.step(.tick(at: at(20))) == [])
  #expect(rules.step(.tool(phase: .start, at: at(21))) == [.start(target: "A", url: page)])
}

// MARK: Lost events

@Test func aLostToolEndIsGivenUpAfterTheTimeLimit() {
  var rules = ClipRules.working()
  rules.frames("A", 3)
  #expect(rules.step(.tick(at: at(179.9))) == [])
  // Nothing from the tool for 180 s: it counts as finished, five seconds after its last event.
  #expect(rules.step(.tick(at: at(180))) == [finish("A", true, 5)])
  #expect(rules.step(.pageOpened(target: "B", url: page + "/b", adopted: false, at: at(181))) == [])
  #expect(rules.step(.tool(phase: .start, at: at(182))) == [.start(target: "A", url: page), .start(target: "B", url: page + "/b")])
}

@Test func aToolEventKeepsAnInFlightCallAlive() {
  var rules = ClipRules.working()
  _ = rules.step(.tool(phase: .end, at: at(100)))
  _ = rules.step(.tool(phase: .start, at: at(100)))
  #expect(rules.step(.tick(at: at(179.9))) == [])
  // Not given up (its last event was 150 s ago); the clip itself is cut at its own limit.
  #expect(rules.step(.tick(at: at(250))) == [finish("A", false, 250)])
  #expect(rules.step(.tick(at: at(260))) == [])
}

@Test func resetFinishesEveryClipAndForgetsTheClient() {
  var rules = ClipRules.working()
  _ = rules.step(.pageOpened(target: "B", url: page + "/b", adopted: false, at: at(0)))
  rules.frames("A", 3)
  #expect(rules.step(.reset(at: at(3))) == [finish("A", true, 3), finish("B", false, 3)])
  // Pages are forgotten and the lost tool call no longer counts as running.
  #expect(rules.step(.tool(phase: .start, at: at(4))) == [])
  #expect(rules.step(.pageOpened(target: "A", url: page, adopted: false, at: at(4))) == [.start(target: "A", url: page)])
  _ = rules.step(.tool(phase: .end, at: at(5)))
  #expect(rules.step(.tick(at: at(10))) == [finish("A", false, 10)])
  #expect(rules.step(.reset(at: at(11))) == [])
}
