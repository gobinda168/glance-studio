import Testing
@testable import GlanceCore

@Suite struct NarrationVoiceTests {
  @Test func resolvesTheNarrationVoice() {
    #expect(NarrationVoice.resolve(preference: nil, hasElevenLabsKey: true) == .cloud(.elevenLabs))
    #expect(NarrationVoice.resolve(preference: nil, hasElevenLabsKey: false) == .kokoro)
    #expect(NarrationVoice.resolve(preference: "minimax", hasElevenLabsKey: true) == .cloud(.miniMax))
    #expect(NarrationVoice.resolve(preference: "elevenlabs", hasElevenLabsKey: false) == .cloud(.elevenLabs))
    #expect(NarrationVoice.resolve(preference: "kokoro", hasElevenLabsKey: true) == .kokoro)
    #expect(NarrationVoice.resolve(preference: "system", hasElevenLabsKey: true) == .mac)
    // Unknown or legacy values never strand the user on a voice that can't speak.
    #expect(NarrationVoice.resolve(preference: "nonsense", hasElevenLabsKey: false) == .kokoro)
    #expect(NarrationVoice.resolve(preference: "", hasElevenLabsKey: true) == .cloud(.elevenLabs))
  }

  @Test func preferenceRoundTrips() {
    for voice in [NarrationVoice.cloud(.elevenLabs), .cloud(.miniMax), .kokoro, .mac] {
      #expect(NarrationVoice.resolve(preference: voice.preference, hasElevenLabsKey: false) == voice)
    }
    #expect(NarrationVoice.mac.preference == "system")
  }

  @Test func fallsBackCloudThenKokoroThenMac() {
    #expect(VoiceTier.next(after: .cloud, kokoroAvailable: true) == .kokoro)
    #expect(VoiceTier.next(after: .cloud, kokoroAvailable: false) == .mac)
    #expect(VoiceTier.next(after: .kokoro, kokoroAvailable: true) == .mac)
    #expect(VoiceTier.next(after: .mac, kokoroAvailable: true) == nil)
  }
}
