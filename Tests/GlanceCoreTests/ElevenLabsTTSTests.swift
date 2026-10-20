import Foundation
import Testing
@testable import GlanceCore

@Suite struct ElevenLabsTTSTests {
  private func body(_ request: URLRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
  }

  @Test func speechRequestAsksForRawPCM() {
    let request = ElevenLabsTTS.speechRequest(key: "sk_test", voice: "Xb7hH8MSUJpSbSDYk0k2", model: "eleven_v4_turbo",
                                              text: "Hello.", previous: "Before.", next: "After.")
    #expect(request.url?.absoluteString
      == "https://api.elevenlabs.io/v1/text-to-speech/Xb7hH8MSUJpSbSDYk0k2/stream?output_format=pcm_24000")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "xi-api-key") == "sk_test")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(request.timeoutInterval == 5)
    let json = body(request)
    #expect(json["text"] as? String == "Hello.")
    #expect(json["model_id"] as? String == "eleven_v4_turbo")
    #expect(json["previous_text"] as? String == "Before.")
    #expect(json["next_text"] as? String == "After.")
  }

  @Test func emptyNeighboursAreLeftOut() {
    let request = ElevenLabsTTS.speechRequest(key: "k", voice: "v", model: "m", text: "Hi.", previous: "  ", next: nil)
    let json = body(request)
    #expect(json["previous_text"] == nil)
    #expect(json["next_text"] == nil)
  }

  @Test func unicodeSurvivesTheBody() {
    let text = "Café “quotes” — and 🚀 rockets."
    let request = ElevenLabsTTS.speechRequest(key: "k", voice: "v", model: "m", text: text, previous: nil, next: nil)
    #expect(body(request)["text"] as? String == text)
  }

  @Test func neighboursAreTrimmedAtWordBoundaries() {
    #expect(ElevenLabsTTS.tail("alpha beta gamma delta", limit: 12) == "gamma delta")
    #expect(ElevenLabsTTS.head("alpha beta gamma delta", limit: 12) == "alpha beta")
    #expect(ElevenLabsTTS.tail("short", limit: 12) == "short")
    #expect(ElevenLabsTTS.head("\n", limit: 12) == nil)
    let long = String(repeating: "word ", count: 200)
    #expect(ElevenLabsTTS.tail(long)!.count <= 500)
    #expect(ElevenLabsTTS.head(long)!.count <= 300)
  }

  @Test func mapsFailures() {
    let quota = Data(#"{"detail":{"status":"quota_exceeded","message":"This request exceeds your quota."}}"#.utf8)
    let voice = Data(#"{"detail":{"status":"voice_not_found","message":"A voice with that ID was not found."}}"#.utf8)
    #expect(ElevenLabsTTS.failure(status: 200, body: Data()) == nil)
    #expect(ElevenLabsTTS.failure(status: 401, body: quota) == .quotaExceeded)
    #expect(ElevenLabsTTS.failure(status: 401, body: Data()) == .invalidKey)
    #expect(ElevenLabsTTS.failure(status: 429, body: Data()) == .rateLimited)
    #expect(ElevenLabsTTS.failure(status: 502, body: Data()) == .server(502))
    #expect(ElevenLabsTTS.failure(status: 404, body: voice) == .rejected("A voice with that ID was not found."))
    #expect(ElevenLabsTTS.failure(status: 422, body: Data()) == .rejected("HTTP 422"))
  }

  @Test func billsFromTheHeaderOrTheText() {
    #expect(ElevenLabsTTS.charactersBilled(header: "2", text: "Okay.") == 2)
    #expect(ElevenLabsTTS.charactersBilled(header: nil, text: "Okay.") == 5)
    #expect(ElevenLabsTTS.charactersBilled(header: "x", text: "Okay.") == 5)
  }

  @Test func decodesTheSubscription() {
    let json = Data(#"{"tier":"free","character_count":66,"character_limit":10000,"next_character_count_reset_unix":1793341533}"#.utf8)
    #expect(ElevenLabsTTS.usage(from: json)
      == Usage(used: 66, limit: 10_000, resetsAt: Date(timeIntervalSince1970: 1_793_341_533)))
    #expect(ElevenLabsTTS.usage(from: Data("{}".utf8)) == nil)
    let request = ElevenLabsTTS.usageRequest(key: "k")
    #expect(request.url?.absoluteString == "https://api.elevenlabs.io/v1/user/subscription")
    #expect(request.value(forHTTPHeaderField: "xi-api-key") == "k")
  }

  @Test func decodesVoices() {
    let json = Data(#"""
    {"voices":[
      {"voice_id":"Xb7hH8MSUJpSbSDYk0k2","name":"Alice - Clear, Engaging Educator","description":"Warm. Clear.",
       "preview_url":"https://storage.googleapis.com/x/alice.mp3"},
      {"voice_id":"abc","name":"Natasha – Sweet Storytelling Voice\t","description":"Sweet and expressive storytelling tone."},
      {"voice_id":"def","name":"Plain","description":null}
    ]}
    """#.utf8)
    let voices = ElevenLabsTTS.voices(from: json)
    #expect(voices?.count == 3)
    #expect(voices?[0] == VoiceOption(id: "Xb7hH8MSUJpSbSDYk0k2", name: "Alice", detail: "Clear, Engaging Educator",
                                      sampleURL: URL(string: "https://storage.googleapis.com/x/alice.mp3")))
    #expect(voices?[1].name == "Natasha")
    #expect(voices?[1].detail == "Sweet Storytelling Voice")
    #expect(voices?[2].detail == "")
    #expect(ElevenLabsTTS.voices(from: Data("nope".utf8)) == nil)
    #expect(ElevenLabsTTS.voicesRequest(key: "k").url?.absoluteString == "https://api.elevenlabs.io/v2/voices?page_size=100")
  }
}
