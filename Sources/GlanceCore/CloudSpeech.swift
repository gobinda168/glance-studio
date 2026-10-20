import Foundation

/// The cloud text-to-speech services Glance can narrate with. The Mac voice isn't one of them: it is the fallback,
/// and what "Mac voice only" means.
public enum ProviderID: String, CaseIterable, Sendable {
  case elevenLabs = "elevenlabs"
  case miniMax = "minimax"

  public var displayName: String {
    switch self {
    case .elevenLabs: "ElevenLabs"
    case .miniMax: "MiniMax"
    }
  }

  /// The Keychain account for this provider's key, under the service `dev.glance.Glance`.
  public var keychainAccount: String { rawValue }

  /// Models offered in Settings, default first.
  public var models: [ModelOption] {
    switch self {
    case .elevenLabs: [
      ModelOption(id: "eleven_v4_turbo", name: "v4 Turbo", detail: "Fast, expressive"),
      ModelOption(id: "eleven_flash_v2_5", name: "Flash v2.5", detail: "Fastest"),
      ModelOption(id: "eleven_multilingual_v2", name: "Multilingual v2", detail: "Steadiest on long text"),
    ]
    case .miniMax: [
      ModelOption(id: "speech-2.6-turbo", name: "Speech 2.6 Turbo", detail: "Fast, low cost"),
      ModelOption(id: "speech-2.8-turbo", name: "Speech 2.8 Turbo", detail: "Newer, fast"),
      ModelOption(id: "speech-2.8-hd", name: "Speech 2.8 HD", detail: "Highest quality"),
    ]
    }
  }

  public var defaultModel: String { models[0].id }

  public var defaultVoice: VoiceOption {
    switch self {
    case .elevenLabs: VoiceOption(id: "Xb7hH8MSUJpSbSDYk0k2", name: "Alice", detail: "Clear, Engaging Educator")
    case .miniMax: VoiceOption(id: "English_Insightful_Speaker", name: "Insightful Speaker", detail: "English")
    }
  }
}

public struct ModelOption: Hashable, Sendable {
  public let id: String
  public let name: String
  public let detail: String

  public init(id: String, name: String, detail: String) {
    self.id = id
    self.name = name
    self.detail = detail
  }
}

public struct VoiceOption: Hashable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let detail: String
  /// A free, pre-recorded sample, when the provider hosts one.
  public let sampleURL: URL?

  public init(id: String, name: String, detail: String, sampleURL: URL? = nil) {
    self.id = id
    self.name = name
    self.detail = detail
    self.sampleURL = sampleURL
  }
}

/// What a provider returns for one request: 16-bit little-endian mono PCM and what it cost.
public struct SpeechAudio: Equatable, Sendable {
  public let pcm: Data
  public let sampleRate: Double
  public let charactersBilled: Int

  public init(pcm: Data, sampleRate: Double, charactersBilled: Int) {
    self.pcm = pcm
    self.sampleRate = sampleRate
    self.charactersBilled = charactersBilled
  }
}

/// Characters used this billing period, for providers that can say.
public struct Usage: Equatable, Sendable {
  public let used: Int
  public let limit: Int
  public let resetsAt: Date?

  public init(used: Int, limit: Int, resetsAt: Date?) {
    self.used = used
    self.limit = limit
    self.resetsAt = resetsAt
  }

  public var remaining: Int { max(0, limit - used) }
}

/// Why a cloud voice couldn't speak, in provider-neutral terms.
public enum TTSFailure: Error, Equatable, Sendable {
  case invalidKey
  case quotaExceeded
  case rateLimited
  case timeout
  case server(Int)
  case network(String)
  case rejected(String)
  /// A local voice (Kokoro) can't speak; the reason is already a full sentence.
  case unavailable(String)

  /// URLSession errors: timeouts are their own reason, everything else is the network.
  public init(transport error: Error) {
    if (error as? URLError)?.code == .timedOut {
      self = .timeout
    } else {
      self = .network(error.localizedDescription)
    }
  }

  /// What the chip under the orb says after "Mac voice · ".
  public func message(provider: String, resetsAt: Date? = nil, timeZone: TimeZone = .current) -> String {
    switch self {
    case .invalidKey: "\(provider) key rejected. Check Settings."
    case .quotaExceeded:
      resetsAt.map { "\(provider) quota used · resets \(UsageLine.day($0, timeZone: timeZone))" }
        ?? "\(provider) balance is empty"
    case .rateLimited: "\(provider) is rate limiting"
    case .timeout: "\(provider) took too long"
    case .server(let status): "\(provider) is having trouble (HTTP \(status))"
    case .network(let reason): "Couldn't reach \(provider): \(reason)"
    case .rejected(let reason): "\(provider): \(reason)"
    case .unavailable(let reason): reason
    }
  }
}

/// The usage line in Settings → Voice.
public enum UsageLine {
  public static func text(_ usage: Usage?, sessionCharacters: Int, timeZone: TimeZone = .current) -> String {
    guard let usage else { return "Pay as you go · \(count(sessionCharacters)) characters this session" }
    var line = "\(count(usage.used)) of \(count(usage.limit)) characters"
    if let reset = usage.resetsAt { line += " · resets \(day(reset, timeZone: timeZone))" }
    return line
  }

  /// "3 Nov".
  public static func day(_ date: Date, timeZone: TimeZone = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "d MMM"
    return formatter.string(from: date)
  }

  static func count(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.locale = Locale(identifier: "en_US")
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
  }
}
