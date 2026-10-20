import Testing
@testable import GlanceCore

@Suite struct KokoroVoicesTests {
  @Test func offersTheBestEnglishVoicesHeartFirst() {
    #expect(KokoroVoices.all.map(\.id) == ["af_heart", "af_bella", "af_nicole", "af_sarah", "am_michael", "am_fenrir",
                                           "bf_emma", "bm_george"])
    #expect(KokoroVoices.defaultVoice.id == "af_heart")
    #expect(KokoroVoices.defaultVoice.name == "Heart")
    #expect(Set(KokoroVoices.all.map(\.id)).count == KokoroVoices.all.count)
    #expect(KokoroVoices.all.allSatisfy { $0.sampleURL == nil })
  }

  @Test func savedIdPicksTheVoiceAndAnythingElseTheDefault() {
    #expect(KokoroVoices.option(id: "bm_george").name == "George")
    #expect(KokoroVoices.option(id: nil).id == "af_heart")
    #expect(KokoroVoices.option(id: "zf_xiaobei").id == "af_heart")
  }

  @Test func unavailableFailureSaysItsOwnReason() {
    #expect(TTSFailure.unavailable("Kokoro unavailable: no model").message(provider: "ElevenLabs")
      == "Kokoro unavailable: no model")
  }
}
