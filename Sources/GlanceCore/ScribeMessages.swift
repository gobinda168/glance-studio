import Foundation

/// What the Scribe session reports, reduced to what dictation needs.
public enum ScribeEvent: Equatable, Sendable {
  case started
  case partial(String)
  case committed(String)
  case failure(kind: String, message: String)
}

/// ElevenLabs Scribe v2 Realtime over WebSocket: the connect URL, outgoing audio chunks and incoming messages.
public enum ScribeMessages {
  public static let endpoint = URL(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
  public static let sampleRate = 16_000

  public static func url(keyterms: [String], zeroRetention: Bool) -> URL {
    var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
    var items = [
      URLQueryItem(name: "model_id", value: "scribe_v2_realtime"),
      URLQueryItem(name: "audio_format", value: "pcm_16000"),
      URLQueryItem(name: "commit_strategy", value: "manual"),
      URLQueryItem(name: "no_verbatim", value: "true"),
    ]
    if zeroRetention { items.append(URLQueryItem(name: "enable_logging", value: "false")) }
    items += keyterms.map { URLQueryItem(name: "keyterms", value: $0) }
    components.queryItems = items
    return components.url!
  }

  /// `previousText` gives Scribe context and belongs on the first chunk only.
  public static func audioChunk(_ pcm: Data, commit: Bool, previousText: String? = nil) -> String {
    var message: [String: Any] = [
      "message_type": "input_audio_chunk",
      "audio_base_64": pcm.base64EncodedString(),
      "commit": commit,
      "sample_rate": sampleRate,
    ]
    if let previousText, !previousText.isEmpty { message["previous_text"] = previousText }
    let data = try! JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
  }

  /// Unknown types, warnings and the timestamped duplicate of a committed transcript decode to nil.
  public static func decode(_ text: String) -> ScribeEvent? {
    guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
      let type = object["message_type"] as? String
    else { return nil }
    switch type {
    case "session_started": return .started
    case "partial_transcript": return .partial(object["text"] as? String ?? "")
    case "committed_transcript": return .committed(object["text"] as? String ?? "")
    default:
      guard let error = object["error"] as? String else { return nil }
      return .failure(kind: type, message: error)
    }
  }

  /// The pill's wording for a failure.
  public static func describe(kind: String, message: String) -> String {
    switch kind {
    case "auth_error": "ElevenLabs rejected the key. Check it in Settings."
    case "quota_exceeded": "Your ElevenLabs quota is used up."
    case "rate_limited", "commit_throttled": "ElevenLabs is rate limiting. Try again in a moment."
    case "insufficient_audio_activity": "Didn't catch that"
    default: "Couldn't reach ElevenLabs: \(message)"
    }
  }
}
