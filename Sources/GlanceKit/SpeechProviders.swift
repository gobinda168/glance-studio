import Foundation
import GlanceCore

/// One cloud text-to-speech service. Everything above this seam (Narrator, budget, cache, Settings) sees only these
/// types, so adding a provider means one new conforming type plus its GlanceCore wire format.
protocol SpeechProvider: Sendable {
  var id: ProviderID { get }
  /// 16-bit mono PCM for the text. `previous` and `next` are context for providers that use it. Throws `TTSFailure`.
  func synthesize(_ text: String, voice: String, model: String, previous: String?, next: String?) async throws
    -> SpeechAudio
  /// Characters left this period, or nil when the service can't say (pay as you go) or the call failed.
  func usage() async -> Usage?
  /// Voices to offer in Settings. Throws `TTSFailure`.
  func voices() async throws -> [VoiceOption]
}

enum SpeechProviders {
  /// Requests set their own idle timeout; no response may take longer than 15 s in total.
  static let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForResource = 15
    return URLSession(configuration: config)
  }()

  static func make(_ id: ProviderID, key: String) -> SpeechProvider {
    switch id {
    case .elevenLabs: ElevenLabsProvider(key: key)
    case .miniMax: MiniMaxProvider(key: key)
    }
  }

  static func key(for id: ProviderID) -> String? {
    KeychainStore.provider(id).read()
  }

  /// Whether `id` has a key, without reading it (no Keychain prompt).
  static func hasKey(_ id: ProviderID) -> Bool {
    KeychainStore.provider(id).exists()
  }

  /// Sends a request; transport errors come back as `TTSFailure`.
  static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw TTSFailure(transport: error)
    }
    guard let http = response as? HTTPURLResponse else { throw TTSFailure.network("no HTTP response") }
    return (data, http)
  }
}

struct ElevenLabsProvider: SpeechProvider {
  let key: String
  var id: ProviderID { .elevenLabs }

  func synthesize(_ text: String, voice: String, model: String, previous: String?, next: String?) async throws
    -> SpeechAudio {
    let request = ElevenLabsTTS.speechRequest(key: key, voice: voice, model: model, text: text,
                                              previous: previous, next: next)
    let (data, response) = try await SpeechProviders.send(request)
    if let failure = ElevenLabsTTS.failure(status: response.statusCode, body: data) { throw failure }
    guard data.count >= 2 else { throw TTSFailure.rejected("returned no audio") }
    let billed = ElevenLabsTTS.charactersBilled(header: response.value(forHTTPHeaderField: "character-cost"), text: text)
    return SpeechAudio(pcm: data, sampleRate: ElevenLabsTTS.sampleRate, charactersBilled: billed)
  }

  func usage() async -> Usage? {
    guard let result = try? await SpeechProviders.send(ElevenLabsTTS.usageRequest(key: key)),
      result.1.statusCode == 200
    else { return nil }
    return ElevenLabsTTS.usage(from: result.0)
  }

  func voices() async throws -> [VoiceOption] {
    let (data, response) = try await SpeechProviders.send(ElevenLabsTTS.voicesRequest(key: key))
    if let failure = ElevenLabsTTS.failure(status: response.statusCode, body: data) { throw failure }
    guard let voices = ElevenLabsTTS.voices(from: data) else { throw TTSFailure.rejected("unreadable voice list") }
    return voices
  }
}

struct MiniMaxProvider: SpeechProvider {
  let key: String
  var id: ProviderID { .miniMax }

  func synthesize(_ text: String, voice: String, model: String, previous: String?, next: String?) async throws
    -> SpeechAudio {
    let request = MiniMaxTTS.speechRequest(key: key, voice: voice, model: model, text: text)
    let (data, response) = try await SpeechProviders.send(request)
    if let failure = MiniMaxTTS.failure(status: response.statusCode, body: data) { throw failure }
    return try MiniMaxTTS.audio(from: data, text: text).get()
  }

  /// Pay as you go: MiniMax has no character quota to report.
  func usage() async -> Usage? { nil }

  func voices() async throws -> [VoiceOption] {
    let (data, response) = try await SpeechProviders.send(MiniMaxTTS.voicesRequest(key: key))
    if let failure = MiniMaxTTS.failure(status: response.statusCode, body: data) { throw failure }
    let voices = try MiniMaxTTS.voices(from: data).get()
    return voices.isEmpty ? MiniMaxTTS.fallbackVoices : voices
  }
}
