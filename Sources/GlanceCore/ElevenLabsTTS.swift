import Foundation

/// ElevenLabs text to speech on the wire. The app's `ElevenLabsProvider` sends these requests.
public enum ElevenLabsTTS {
  public static let sampleRate = 24_000.0
  static let host = "https://api.elevenlabs.io"

  /// One paragraph as raw 24 kHz PCM. The neighbouring paragraphs keep intonation flowing across requests.
  public static func speechRequest(key: String, voice: String, model: String, text: String,
                                   previous: String?, next: String?) -> URLRequest {
    var components = URLComponents(string: "\(host)/v1/text-to-speech/\(voice)/stream")!
    components.queryItems = [URLQueryItem(name: "output_format", value: "pcm_24000")]
    var request = URLRequest(url: components.url!, timeoutInterval: 5)
    request.httpMethod = "POST"
    request.setValue(key, forHTTPHeaderField: "xi-api-key")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    var body: [String: Any] = ["text": text, "model_id": model]
    if let previous = previous.flatMap({ tail($0) }) { body["previous_text"] = previous }
    if let next = next.flatMap({ head($0) }) { body["next_text"] = next }
    request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    return request
  }

  /// The last ≤`limit` characters, starting at a word. Nil when blank.
  static func tail(_ text: String, limit: Int = 500) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard trimmed.count > limit else { return trimmed }
    let cut = trimmed.suffix(limit)
    return String(cut.firstIndex(of: " ").map { cut[cut.index(after: $0)...] } ?? cut)
  }

  /// The first ≤`limit` characters, ending at a word. Nil when blank.
  static func head(_ text: String, limit: Int = 300) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard trimmed.count > limit else { return trimmed }
    let cut = trimmed.prefix(limit)
    return String(cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut)
  }

  /// Nil for success. A `quota_exceeded` body wins over the status code (ElevenLabs sends it with 401).
  public static func failure(status: Int, body: Data) -> TTSFailure? {
    if (200..<300).contains(status) { return nil }
    let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    let detail = object?["detail"] as? [String: Any]
    if detail?["status"] as? String == "quota_exceeded" { return .quotaExceeded }
    switch status {
    case 401: return .invalidKey
    case 429: return .rateLimited
    case 500...: return .server(status)
    default: return .rejected(detail?["message"] as? String ?? "HTTP \(status)")
    }
  }

  /// The `character-cost` response header, or the text length when it's missing.
  public static func charactersBilled(header: String?, text: String) -> Int {
    header.flatMap { Int($0) } ?? text.count
  }

  public static func usageRequest(key: String) -> URLRequest {
    get("\(host)/v1/user/subscription", key: key)
  }

  public static func usage(from data: Data) -> Usage? {
    struct Body: Decodable {
      let character_count: Int
      let character_limit: Int
      let next_character_count_reset_unix: Int?
    }
    guard let body = try? JSONDecoder().decode(Body.self, from: data) else { return nil }
    return Usage(used: body.character_count, limit: body.character_limit,
                 resetsAt: body.next_character_count_reset_unix.map { Date(timeIntervalSince1970: TimeInterval($0)) })
  }

  public static func voicesRequest(key: String) -> URLRequest {
    get("\(host)/v2/voices?page_size=100", key: key)
  }

  /// Premade, own and saved library voices. Names like "Alice - Clear, Engaging Educator" are split into the name
  /// and the detail; otherwise the detail is the description's first sentence.
  public static func voices(from data: Data) -> [VoiceOption]? {
    struct Body: Decodable {
      struct Voice: Decodable {
        let voice_id: String
        let name: String
        let description: String?
        let preview_url: String?
      }
      let voices: [Voice]
    }
    guard let body = try? JSONDecoder().decode(Body.self, from: data) else { return nil }
    return body.voices.map { voice in
      let (name, label) = split(voice.name)
      return VoiceOption(id: voice.voice_id, name: name,
                         detail: label ?? SpeechText.firstSentence(voice.description ?? ""),
                         sampleURL: voice.preview_url.flatMap(URL.init(string:)))
    }
  }

  static func split(_ name: String) -> (String, String?) {
    for separator in [" - ", " – "] {
      if let range = name.range(of: separator) {
        return (name[..<range.lowerBound].trimmingCharacters(in: .whitespaces),
                name[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines))
      }
    }
    return (name.trimmingCharacters(in: .whitespacesAndNewlines), nil)
  }

  private static func get(_ url: String, key: String) -> URLRequest {
    var request = URLRequest(url: URL(string: url)!, timeoutInterval: 10)
    request.httpMethod = "GET"
    request.setValue(key, forHTTPHeaderField: "xi-api-key")
    return request
  }
}
