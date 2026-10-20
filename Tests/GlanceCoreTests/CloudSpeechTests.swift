import Foundation
import Testing
@testable import GlanceCore

@Suite struct CloudSpeechTests {
  let utc = TimeZone(identifier: "UTC")!
  /// 2026-11-03 12:00 UTC.
  let reset = Date(timeIntervalSince1970: 1_793_707_200)

  @Test func providersHaveKeychainAccountsModelsAndVoices() {
    #expect(ProviderID.elevenLabs.keychainAccount == "elevenlabs")
    #expect(ProviderID.miniMax.keychainAccount == "minimax")
    for provider in ProviderID.allCases {
      #expect(!provider.displayName.isEmpty)
      #expect(provider.models.map(\.id).contains(provider.defaultModel))
      #expect(!provider.defaultVoice.id.isEmpty)
    }
    #expect(ProviderID.elevenLabs.defaultModel == "eleven_v4_turbo")
    #expect(ProviderID.elevenLabs.defaultVoice.id == "Xb7hH8MSUJpSbSDYk0k2")
    #expect(ProviderID.miniMax.defaultModel == "speech-2.6-turbo")
    #expect(ProviderID.miniMax.defaultVoice.id == "English_Insightful_Speaker")
  }

  @Test func usageKnowsWhatIsLeft() {
    #expect(Usage(used: 2_140, limit: 10_000, resetsAt: nil).remaining == 7_860)
    #expect(Usage(used: 12_000, limit: 10_000, resetsAt: nil).remaining == 0)
  }

  @Test func failureMessagesNameTheProvider() {
    #expect(TTSFailure.invalidKey.message(provider: "MiniMax") == "MiniMax key rejected. Check Settings.")
    #expect(TTSFailure.quotaExceeded.message(provider: "ElevenLabs", resetsAt: reset, timeZone: utc)
      == "ElevenLabs quota used · resets 3 Nov")
    #expect(TTSFailure.quotaExceeded.message(provider: "MiniMax") == "MiniMax balance is empty")
    #expect(TTSFailure.rateLimited.message(provider: "ElevenLabs") == "ElevenLabs is rate limiting")
    #expect(TTSFailure.timeout.message(provider: "ElevenLabs") == "ElevenLabs took too long")
    #expect(TTSFailure.server(503).message(provider: "ElevenLabs") == "ElevenLabs is having trouble (HTTP 503)")
    #expect(TTSFailure.network("offline").message(provider: "MiniMax") == "Couldn't reach MiniMax: offline")
    #expect(TTSFailure.rejected("voice not found").message(provider: "MiniMax") == "MiniMax: voice not found")
  }

  @Test func transportErrorsSplitTimeoutsFromTheNetwork() {
    #expect(TTSFailure(transport: URLError(.timedOut)) == .timeout)
    guard case .network = TTSFailure(transport: URLError(.notConnectedToInternet)) else {
      Issue.record("expected .network")
      return
    }
  }

  @Test func usageLineShowsQuotaOrPayAsYouGo() {
    let usage = Usage(used: 2_140, limit: 10_000, resetsAt: reset)
    #expect(UsageLine.text(usage, sessionCharacters: 0, timeZone: utc) == "2,140 of 10,000 characters · resets 3 Nov")
    #expect(UsageLine.text(Usage(used: 5, limit: 10_000, resetsAt: nil), sessionCharacters: 0)
      == "5 of 10,000 characters")
    #expect(UsageLine.text(nil, sessionCharacters: 1_234) == "Pay as you go · 1,234 characters this session")
  }
}
