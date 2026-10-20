import Testing
@testable import GlanceCore

@Test func aCachedReadAlwaysShows() {
  #expect(AutoClaude.read(auto: false, cached: true, busy: false) == .showCached)
  #expect(AutoClaude.read(auto: true, cached: true, busy: true) == .showCached)
}

@Test func onStartsAReadOffOffersTheButton() {
  #expect(AutoClaude.read(auto: true, cached: false, busy: false) == .start)
  #expect(AutoClaude.read(auto: false, cached: false, busy: false) == .offer)
}

@Test func aReadUnderWayFailedOrUnavailableWaits() {
  #expect(AutoClaude.read(auto: true, cached: false, busy: true) == .wait)
  #expect(AutoClaude.read(auto: false, cached: false, busy: true) == .wait)
}

@Test func aNewHeadOffersTheButtonWhenOff() {
  // The page's read is .ready for the old head (not busy), and the new head isn't cached.
  #expect(AutoClaude.read(auto: false, cached: false, busy: false) == .offer)
}
