import Foundation
import Testing
@testable import GlanceCore

@Suite struct MiniMaxTTSTests {
  @Test func speechRequestAsksForHexPCM() throws {
    let request = MiniMaxTTS.speechRequest(key: "mm_key", voice: "English_Insightful_Speaker",
                                           model: "speech-2.6-turbo", text: "Hello — café.")
    #expect(request.url?.absoluteString == "https://api.minimax.io/v1/t2a_v2")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer mm_key")
    #expect(request.timeoutInterval == 15)
    let json = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
    #expect(json["model"] as? String == "speech-2.6-turbo")
    #expect(json["text"] as? String == "Hello — café.")
    #expect(json["stream"] as? Bool == false)
    #expect(json["output_format"] as? String == "hex")
    let voice = json["voice_setting"] as? [String: Any]
    #expect(voice?["voice_id"] as? String == "English_Insightful_Speaker")
    let audio = json["audio_setting"] as? [String: Any]
    #expect(audio?["format"] as? String == "pcm")
    #expect(audio?["sample_rate"] as? Int == 24_000)
    #expect(audio?["channel"] as? Int == 1)
  }

  @Test func decodesHexAudioAndUsage() {
    let json = Data(#"{"data":{"audio":"0001ff7F","status":2},"extra_info":{"usage_characters":7},"base_resp":{"status_code":0,"status_msg":"success"}}"#.utf8)
    #expect(MiniMaxTTS.audio(from: json, text: "Hello.")
      == .success(SpeechAudio(pcm: Data([0x00, 0x01, 0xFF, 0x7F]), sampleRate: 24_000, charactersBilled: 7)))
  }

  @Test func missingUsageBillsTheText() throws {
    let json = Data(#"{"data":{"audio":"0000"},"base_resp":{"status_code":0}}"#.utf8)
    #expect(try MiniMaxTTS.audio(from: json, text: "Hello.").get().charactersBilled == 6)
  }

  @Test func errorsArriveOnHTTP200() {
    let balance = Data(#"{"data":null,"base_resp":{"status_code":1008,"status_msg":"insufficient balance"}}"#.utf8)
    #expect(MiniMaxTTS.audio(from: balance, text: "x") == .failure(.quotaExceeded))
  }

  @Test func emptyOrBrokenAudioIsAFailure() {
    let empty = Data(#"{"data":{"audio":""},"base_resp":{"status_code":0}}"#.utf8)
    let odd = Data(#"{"data":{"audio":"abc"},"base_resp":{"status_code":0}}"#.utf8)
    #expect(MiniMaxTTS.audio(from: empty, text: "x") == .failure(.rejected("returned no audio")))
    #expect(MiniMaxTTS.audio(from: odd, text: "x") == .failure(.rejected("returned no audio")))
    // One byte is less than a single 16-bit sample: nothing to play, so it must not count as audio.
    let oneByte = Data(#"{"data":{"audio":"00"},"base_resp":{"status_code":0}}"#.utf8)
    #expect(MiniMaxTTS.audio(from: oneByte, text: "x") == .failure(.rejected("returned no audio")))
    #expect(MiniMaxTTS.audio(from: Data("<html>".utf8), text: "x") == .failure(.rejected("unreadable response")))
  }

  @Test func mapsStatusCodes() {
    #expect(MiniMaxTTS.failure(code: 1004, message: "") == .invalidKey)
    #expect(MiniMaxTTS.failure(code: 2049, message: "") == .invalidKey)
    #expect(MiniMaxTTS.failure(code: 1008, message: "") == .quotaExceeded)
    #expect(MiniMaxTTS.failure(code: 2056, message: "") == .quotaExceeded)
    #expect(MiniMaxTTS.failure(code: 1002, message: "") == .rateLimited)
    #expect(MiniMaxTTS.failure(code: 1039, message: "") == .rateLimited)
    #expect(MiniMaxTTS.failure(code: 1001, message: "") == .timeout)
    #expect(MiniMaxTTS.failure(code: 1024, message: "") == .server(1024))
    #expect(MiniMaxTTS.failure(code: 2042, message: "You don't have access to this voice_id")
      == .rejected("You don't have access to this voice_id"))
    #expect(MiniMaxTTS.failure(code: 2013, message: "") == .rejected("error 2013"))
  }

  @Test func mapsHTTPFailures() {
    let auth = Data(#"{"base_resp":{"status_code":2049,"status_msg":"invalid api key"}}"#.utf8)
    #expect(MiniMaxTTS.failure(status: 200, body: Data()) == nil)
    #expect(MiniMaxTTS.failure(status: 401, body: auth) == .invalidKey)
    #expect(MiniMaxTTS.failure(status: 401, body: Data()) == .invalidKey)
    #expect(MiniMaxTTS.failure(status: 429, body: Data()) == .rateLimited)
    #expect(MiniMaxTTS.failure(status: 500, body: Data()) == .server(500))
    #expect(MiniMaxTTS.failure(status: 404, body: Data()) == .rejected("HTTP 404"))
  }

  @Test func decodesEnglishSystemVoices() {
    let json = Data(#"""
    {"system_voice":[
      {"voice_id":"English_Insightful_Speaker","voice_name":"Insightful Speaker","description":["Clear and thoughtful. Good for explainers."]},
      {"voice_id":"English_Graceful_Lady","description":[]},
      {"voice_id":"Chinese (Mandarin)_Reliable_Executive","voice_name":"Steady Executive","description":["Calm."]}
    ],"base_resp":{"status_code":0,"status_msg":"success"}}
    """#.utf8)
    let voices = try? MiniMaxTTS.voices(from: json).get()
    #expect(voices == [
      VoiceOption(id: "English_Insightful_Speaker", name: "Insightful Speaker", detail: "Clear and thoughtful."),
      VoiceOption(id: "English_Graceful_Lady", name: "Graceful Lady", detail: "English"),
    ])
    let denied = Data(#"{"base_resp":{"status_code":2049,"status_msg":"invalid api key"}}"#.utf8)
    #expect(MiniMaxTTS.voices(from: denied) == .failure(.invalidKey))
    let request = MiniMaxTTS.voicesRequest(key: "k")
    #expect(request.url?.absoluteString == "https://api.minimax.io/v1/get_voice")
    #expect(String(decoding: request.httpBody ?? Data(), as: UTF8.self) == #"{"voice_type":"system"}"#)
    #expect(MiniMaxTTS.fallbackVoices.first?.id == "English_Insightful_Speaker")
  }
}
