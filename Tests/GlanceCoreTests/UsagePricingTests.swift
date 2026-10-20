import Foundation
import Testing
@testable import GlanceCore

private func record(_ model: String, input: Int = 0, output: Int = 0, write5m: Int = 0, write1h: Int = 0,
                    read: Int = 0, fast: Bool = false) -> UsageRecord {
  UsageRecord(messageID: "m", time: Date(timeIntervalSince1970: 0), model: model, sessionID: "s", project: "/p",
              subagent: false, fast: fast, input: input, output: output, cacheWrite5m: write5m,
              cacheWrite1h: write1h, cacheRead: read)
}

@Test func modelIDsLoseTheirTagsDatesAndPlatformPrefixes() {
  #expect(UsagePricing.normalize("claude-opus-5-5[1m]") == "claude-opus-5-5")
  #expect(UsagePricing.normalize("claude-haiku-4-5-20251001") == "claude-haiku-4-5")
  #expect(UsagePricing.normalize("us.anthropic.claude-sonnet-5-5") == "claude-sonnet-5-5")
  #expect(UsagePricing.normalize("claude-opus-4-5@20251101") == "claude-opus-4-5")
  #expect(UsagePricing.normalize("Claude-Opus-5") == "claude-opus-5")
}

@Test func theLongestKnownIDWinsSoOpus55IsNotPricedAsOpus5() {
  #expect(UsagePricing.price(for: "claude-opus-5-5")?.input == 4)
  #expect(UsagePricing.price(for: "claude-opus-5")?.input == 5)
  #expect(UsagePricing.price(for: "claude-opus-5-20260301")?.input == 5)
  #expect(UsagePricing.price(for: "claude-fable-5-1")?.cacheRead == 0.25)
  #expect(UsagePricing.price(for: "claude-fable-5")?.cacheRead == 1)
  #expect(UsagePricing.price(for: "claude-haiku-4-5-20251001")?.output == 5)
  #expect(UsagePricing.price(for: "claude-sonnet-4-5") == nil)
  #expect(UsagePricing.price(for: "gpt-5") == nil)
}

@Test func costAddsEveryKindAtItsRate() throws {
  // Opus 5.5: $4 in, $20 out, $0.20 read; 5 min write 1.25 × $4 = $5; 1 h write 2 × $4 = $8 (per million).
  let cost = try #require(UsagePricing.cost(record("claude-opus-5-5", input: 1_000_000, output: 1_000_000,
                                                   write5m: 1_000_000, write1h: 1_000_000, read: 1_000_000)))
  #expect(abs(cost - (4 + 20 + 5 + 8 + 0.2)) < 1e-9)
}

@Test func fastModeDoublesTheCostAndUnknownModelsHaveNone() throws {
  let normal = try #require(UsagePricing.cost(record("claude-opus-5-5", output: 1_000_000)))
  let fast = try #require(UsagePricing.cost(record("claude-opus-5-5", output: 1_000_000, fast: true)))
  #expect(abs(normal - 20) < 1e-9)
  #expect(abs(fast - 40) < 1e-9)
  #expect(UsagePricing.cost(record("claude-mystery-9", output: 10)) == nil)
}

@Test func displayNamesReadLikeTheModelsNames() {
  #expect(UsagePricing.displayName("claude-opus-5-5") == "Opus 5.5")
  #expect(UsagePricing.displayName("claude-haiku-4-5-20251001") == "Haiku 4.5")
  #expect(UsagePricing.displayName("claude-fable-5-1[1m]") == "Fable 5.1")
  #expect(UsagePricing.displayName("claude-opus-5") == "Opus 5")
  #expect(UsagePricing.displayName("some-local-model") == "some-local-model")
}

@Test func tokensAddUpByKind() {
  let tokens = record("m", input: 1, output: 2, write5m: 3, write1h: 4, read: 5).tokens
  #expect(tokens == UsageTokens(input: 1, output: 2, cacheWrite: 7, cacheRead: 5))
  #expect(tokens.total == 15)
  #expect((tokens + tokens).total == 30)
}
