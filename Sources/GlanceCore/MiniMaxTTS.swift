import Foundation

/// MiniMax text to speech (T2A v2) on the wire. Errors usually arrive as HTTP 200 with a non-zero
/// `base_resp.status_code`, so every response is checked for one.
public enum MiniMaxTTS {
  public static let sampleRate = 24_000.0
  static let host = "https://api.minimax.io"

  /// One paragraph as hex-encoded 24 kHz PCM. Not streamed, so the first byte arrives only when the whole paragraph
  /// is ready: the idle timeout is the full 15 s.
  public static func speechRequest(key: String, voice: String, model: String, text: String) -> URLRequest {
    let body: [String: Any] = [
      "model": model,
      "text": text,
      "stream": false,
      "voice_setting": ["voice_id": voice, "speed": 1],
      "audio_setting": ["sample_rate": 24_000, "format": "pcm", "channel": 1],
      "output_format": "hex",
      "language_boost": "English",
    ]
    return post("\(host)/v1/t2a_v2", key: key, body: body, timeout: 15)
  }

  struct BaseResp: Decodable {
    let status_code: Int
    let status_msg: String?
  }

  public static func audio(from data: Data, text: String) -> Result<SpeechAudio, TTSFailure> {
    struct Body: Decodable {
      struct Audio: Decodable { let audio: String? }
      struct Extra: Decodable { let usage_characters: Int? }
      let data: Audio?
      let extra_info: Extra?
      let base_resp: BaseResp?
    }
    guard let body = try? JSONDecoder().decode(Body.self, from: data) else {
      return .failure(.rejected("unreadable response"))
    }
    if let failure = failure(base: body.base_resp) { return .failure(failure) }
    // Fewer than 2 bytes is not even one sample: treat it as no audio so the Mac voice reads the paragraph.
    guard let hex = body.data?.audio, let pcm = bytes(hex: hex), pcm.count >= 2 else {
      return .failure(.rejected("returned no audio"))
    }
    return .success(SpeechAudio(pcm: pcm, sampleRate: sampleRate,
                                charactersBilled: body.extra_info?.usage_characters ?? text.count))
  }

  /// Nil for a 2xx status. A `base_resp` in the body says more than the status, so it wins.
  public static func failure(status: Int, body: Data) -> TTSFailure? {
    if (200..<300).contains(status) { return nil }
    struct Wrapper: Decodable { let base_resp: BaseResp? }
    if let base = (try? JSONDecoder().decode(Wrapper.self, from: body))?.base_resp, let failure = failure(base: base) {
      return failure
    }
    switch status {
    case 401, 403: return .invalidKey
    case 429: return .rateLimited
    case 500...: return .server(status)
    default: return .rejected("HTTP \(status)")
    }
  }

  /// MiniMax's documented error codes.
  public static func failure(code: Int, message: String) -> TTSFailure {
    switch code {
    case 1004, 2049: .invalidKey
    case 1008, 2056: .quotaExceeded
    case 1002, 1039, 1041, 2045: .rateLimited
    case 1001: .timeout
    case 1000, 1024, 1033: .server(code)
    default: .rejected(message.isEmpty ? "error \(code)" : message)
    }
  }

  static func failure(base: BaseResp?) -> TTSFailure? {
    guard let base, base.status_code != 0 else { return nil }
    return failure(code: base.status_code, message: base.status_msg ?? "")
  }

  public static func voicesRequest(key: String) -> URLRequest {
    post("\(host)/v1/get_voice", key: key, body: ["voice_type": "system"], timeout: 10)
  }

  /// English system voices only: the narration is English.
  public static func voices(from data: Data) -> Result<[VoiceOption], TTSFailure> {
    struct Body: Decodable {
      struct Voice: Decodable {
        let voice_id: String
        let voice_name: String?
        let description: [String]?
      }
      let system_voice: [Voice]?
      let base_resp: BaseResp?
    }
    guard let body = try? JSONDecoder().decode(Body.self, from: data) else {
      return .failure(.rejected("unreadable voice list"))
    }
    if let failure = failure(base: body.base_resp) { return .failure(failure) }
    return .success((body.system_voice ?? []).filter { $0.voice_id.hasPrefix("English_") }.map { voice in
      let name = voice.voice_name
        ?? voice.voice_id.dropFirst("English_".count).replacingOccurrences(of: "_", with: " ")
      let detail = voice.description?.first.map { SpeechText.firstSentence($0) } ?? ""
      return VoiceOption(id: voice.voice_id, name: name, detail: detail.isEmpty ? "English" : detail)
    })
  }

  /// Shown when the voice list comes back empty.
  public static let fallbackVoices = [
    VoiceOption(id: "English_Insightful_Speaker", name: "Insightful Speaker", detail: "English"),
    VoiceOption(id: "English_Graceful_Lady", name: "Graceful Lady", detail: "English"),
    VoiceOption(id: "English_Persuasive_Man", name: "Persuasive Man", detail: "English"),
  ]

  static func bytes(hex: String) -> Data? {
    guard hex.utf8.count % 2 == 0 else { return nil }
    var out = Data(capacity: hex.utf8.count / 2)
    var high: UInt8?
    for char in hex.utf8 {
      let value: UInt8
      switch char {
      case 48...57: value = char - 48
      case 97...102: value = char - 87
      case 65...70: value = char - 55
      default: return nil
      }
      if let first = high {
        out.append(first << 4 | value)
        high = nil
      } else {
        high = value
      }
    }
    return out
  }

  private static func post(_ url: String, key: String, body: [String: Any], timeout: TimeInterval) -> URLRequest {
    var request = URLRequest(url: URL(string: url)!, timeoutInterval: timeout)
    request.httpMethod = "POST"
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    return request
  }
}
