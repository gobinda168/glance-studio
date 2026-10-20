import Testing
@testable import GlanceCore

@Suite struct VoiceBudgetTests {
  @Test func unknownRemainingTriesTheCloud() {
    var budget = VoiceBudget()
    #expect(budget.choose(characters: 5_000, cached: false) == .cloud)
  }

  @Test func spendingCountsDown() {
    var budget = VoiceBudget(remaining: 1_000)
    budget.spent(400)
    #expect(budget.remaining == 600)
    budget.spent(900)
    #expect(budget.remaining == 0)
  }

  @Test func aParagraphLongerThanWhatIsLeftFallsBackForTheRestOfTheReply() {
    var budget = VoiceBudget(remaining: 300)
    #expect(budget.choose(characters: 200, cached: false) == .cloud)
    #expect(budget.choose(characters: 400, cached: false) == .system(.quotaExceeded))
    // Sticky: even a short paragraph that would fit stays on the Mac voice.
    #expect(budget.choose(characters: 10, cached: false) == .system(.quotaExceeded))
    budget.newReply()
    #expect(budget.choose(characters: 10, cached: false) == .cloud)
  }

  @Test func cachedAudioIsAlwaysFree() {
    var budget = VoiceBudget(remaining: 0)
    budget.failed(.network("offline"))
    #expect(budget.choose(characters: 900, cached: true) == .cloud)
  }

  @Test func failuresStickUntilTheNextReply() {
    var budget = VoiceBudget(remaining: 5_000)
    budget.failed(.timeout)
    #expect(budget.choose(characters: 10, cached: false) == .system(.timeout))
    #expect(budget.remaining == 5_000)
    budget.newReply()
    #expect(budget.choose(characters: 10, cached: false) == .cloud)
  }

  @Test func quotaExceededEmptiesTheBudget() {
    var budget = VoiceBudget(remaining: 5_000)
    budget.failed(.quotaExceeded)
    #expect(budget.remaining == 0)
    budget.newReply()
    #expect(budget.choose(characters: 10, cached: false) == .system(.quotaExceeded))
  }

  @Test func resetForgetsEverything() {
    var budget = VoiceBudget(remaining: 0)
    budget.failed(.invalidKey)
    budget.reset()
    #expect(budget.remaining == nil)
    #expect(budget.fallback == nil)
    budget.setRemaining(42)
    #expect(budget.remaining == 42)
  }
}
