import Foundation
import Testing
@testable import GlanceCore

@Suite struct PRLookupsTests {
  let now = Date(timeIntervalSince1970: 10_000)
  func candidate(_ key: String, live: Bool = true) -> PRLookups.Candidate { PRLookups.Candidate(key: key, live: live) }

  @Test func fiveBranchesWithNoPRAreAllLookedUpWithoutAnythingElseHappeningBetween() {
    let candidates = (1...5).map { candidate("r\nb\($0)") }
    var looked: [String: Date] = [:]
    var order: [String] = []
    while let next = PRLookups.next(candidates, looked: looked, now: now) {
      looked[next.key] = now
      order.append(next.key)
    }
    #expect(order == candidates.map(\.key))
  }

  @Test func aBranchIsAskedAgainAMinuteLaterWhileLiveAndTenOnceEnded() {
    let candidates = [candidate("live", live: true), candidate("done", live: false)]
    let looked = ["live": now, "done": now]
    #expect(PRLookups.next(candidates, looked: looked, now: now.addingTimeInterval(59)) == nil)
    #expect(PRLookups.next(candidates, looked: looked, now: now.addingTimeInterval(61))?.key == "live")
    let later = now.addingTimeInterval(599)
    #expect(PRLookups.next([candidate("done", live: false)], looked: looked, now: later) == nil)
    #expect(PRLookups.next([candidate("done", live: false)], looked: looked, now: now.addingTimeInterval(601))?.key == "done")
  }

  @Test func aBranchSeenTwiceIsOneLookup() {
    let twice = [candidate("a"), candidate("a")]
    var looked: [String: Date] = [:]
    let first = PRLookups.next(twice, looked: looked, now: now)
    looked["a"] = now
    #expect(first?.key == "a")
    #expect(PRLookups.next(twice, looked: looked, now: now) == nil)
  }

  @Test func aLiveSessionOnABranchAlsoEndedStillCountsAsLive() {
    // Two sessions on one branch: the live one sets the rate.
    let candidates = [candidate("a", live: false), candidate("a", live: true)]
    #expect(PRLookups.next(candidates, looked: ["a": now], now: now.addingTimeInterval(61))?.key == "a")
  }
}
