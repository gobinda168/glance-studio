import Foundation
import Testing
@testable import GlanceCore

@Suite struct ScribeMessagesTests {
  private func items(_ url: URL) -> [URLQueryItem] {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
  }

  @Test func connectURLCarriesConfigAndKeyterms() {
    let url = ScribeMessages.url(keyterms: ["useEffect", "Transcript.swift"], zeroRetention: true)
    #expect(url.absoluteString.hasPrefix("wss://api.elevenlabs.io/v1/speech-to-text/realtime?"))
    let query = items(url)
    #expect(query.contains(URLQueryItem(name: "model_id", value: "scribe_v2_realtime")))
    #expect(query.contains(URLQueryItem(name: "audio_format", value: "pcm_16000")))
    #expect(query.contains(URLQueryItem(name: "commit_strategy", value: "manual")))
    #expect(query.contains(URLQueryItem(name: "no_verbatim", value: "true")))
    #expect(query.contains(URLQueryItem(name: "enable_logging", value: "false")))
    #expect(query.filter { $0.name == "keyterms" }.map(\.value) == ["useEffect", "Transcript.swift"])
  }

  @Test func zeroRetentionOffOmitsLoggingFlag() {
    let query = items(ScribeMessages.url(keyterms: [], zeroRetention: false))
    #expect(!query.contains { $0.name == "enable_logging" })
    #expect(!query.contains { $0.name == "keyterms" })
  }

  @Test func encodesAudioChunks() throws {
    let pcm = Data([0x01, 0x00, 0xFF, 0x7F])
    let first = try JSONSerialization.jsonObject(
      with: Data(ScribeMessages.audioChunk(pcm, commit: false, previousText: "About React Fiber").utf8)) as! [String: Any]
    #expect(first["message_type"] as? String == "input_audio_chunk")
    #expect(first["audio_base_64"] as? String == pcm.base64EncodedString())
    #expect(first["commit"] as? Bool == false)
    #expect(first["sample_rate"] as? Int == 16_000)
    #expect(first["previous_text"] as? String == "About React Fiber")

    let last = try JSONSerialization.jsonObject(
      with: Data(ScribeMessages.audioChunk(pcm, commit: true, previousText: nil).utf8)) as! [String: Any]
    #expect(last["commit"] as? Bool == true)
    #expect(last["previous_text"] == nil)
  }

  @Test func decodesServerMessages() {
    #expect(ScribeMessages.decode(#"{"message_type":"session_started","session_id":"s","config":{}}"#) == .started)
    #expect(ScribeMessages.decode(#"{"message_type":"partial_transcript","text":"rename use"}"#) == .partial("rename use"))
    #expect(ScribeMessages.decode(#"{"message_type":"committed_transcript","text":"Rename useEffect."}"#)
      == .committed("Rename useEffect."))
    #expect(ScribeMessages.decode(#"{"message_type":"auth_error","error":"Invalid API key"}"#)
      == .failure(kind: "auth_error", message: "Invalid API key"))
    #expect(ScribeMessages.decode(#"{"message_type":"insufficient_audio_activity","error":"no speech"}"#)
      == .failure(kind: "insufficient_audio_activity", message: "no speech"))
  }

  @Test func ignoresUnknownAndNonErrorMessages() {
    #expect(ScribeMessages.decode(#"{"message_type":"warning","warning":"slow"}"#) == nil)
    #expect(ScribeMessages.decode(#"{"message_type":"committed_transcript_with_timestamps","text":"x","words":[]}"#) == nil)
    #expect(ScribeMessages.decode(#"{"message_type":"brand_new_type"}"#) == nil)
    #expect(ScribeMessages.decode("not json") == nil)
  }

  @Test func describesFailuresForThePill() {
    #expect(ScribeMessages.describe(kind: "auth_error", message: "x") == "ElevenLabs rejected the key. Check it in Settings.")
    #expect(ScribeMessages.describe(kind: "quota_exceeded", message: "x") == "Your ElevenLabs quota is used up.")
    #expect(ScribeMessages.describe(kind: "insufficient_audio_activity", message: "x") == "Didn't catch that")
    #expect(ScribeMessages.describe(kind: "network", message: "The Internet connection appears to be offline.")
      == "Couldn't reach ElevenLabs: The Internet connection appears to be offline.")
  }
}
