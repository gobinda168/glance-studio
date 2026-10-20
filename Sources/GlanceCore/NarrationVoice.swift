/// Who narrates: a cloud provider, Kokoro on this Mac, or the Mac voice.
public enum NarrationVoice: Equatable, Sendable {
  case cloud(ProviderID)
  case kokoro
  case mac

  /// `preference` is the saved `voiceProvider` (`elevenlabs`, `minimax`, `kokoro`, `system`). With none, or one
  /// Glance doesn't know: ElevenLabs once its key is saved, else Kokoro.
  public static func resolve(preference: String?, hasElevenLabsKey: Bool) -> NarrationVoice {
    switch preference {
    case "kokoro"?: return .kokoro
    case "system"?: return .mac
    case let value?:
      if let id = ProviderID(rawValue: value) { return .cloud(id) }
    case nil:
      break
    }
    return hasElevenLabsKey ? .cloud(.elevenLabs) : .kokoro
  }

  /// The value saved for this choice; `resolve` reads it back.
  public var preference: String {
    switch self {
    case .cloud(let id): id.rawValue
    case .kokoro: "kokoro"
    case .mac: "system"
    }
  }
}

/// Who reads a paragraph. Narration tries them in this order.
public enum VoiceTier: Equatable, Sendable {
  case cloud, kokoro, mac

  /// Who reads when `tier` can't: Kokoro after the cloud when it's available, the Mac voice after that.
  public static func next(after tier: VoiceTier, kokoroAvailable: Bool) -> VoiceTier? {
    switch tier {
    case .cloud: kokoroAvailable ? .kokoro : .mac
    case .kokoro: .mac
    case .mac: nil
    }
  }
}
