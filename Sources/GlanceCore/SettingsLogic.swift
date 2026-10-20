import Foundation

/// The ElevenLabs API key as pasted, cleaned up, and how it is shown once saved.
public enum APIKey {
  /// Pasted keys often carry a trailing newline or spaces; whitespace is never part of a key.
  public static func normalized(_ raw: String) -> String {
    raw.filter { !$0.isWhitespace }
  }

  /// `••••` plus the last 4 characters; only dots for keys too short to reveal anything.
  public static func masked(_ key: String) -> String {
    key.count > 8 ? "••••" + key.suffix(4) : "••••"
  }
}

/// What Settings shows after checking a key.
public enum KeyCheckResult: Equatable, Sendable {
  case connected
  case invalidKey
  case failed(String)

  public var message: String {
    switch self {
    case .connected: "Connected"
    case .invalidKey: "Invalid key. ElevenLabs rejected it."
    case .failed(let reason): reason
    }
  }
}

public enum ElevenLabsKeyCheck {
  public static let url = URL(string: "https://api.elevenlabs.io/v1/user")!

  public static func request(key: String) -> URLRequest {
    var request = URLRequest(url: url, timeoutInterval: 10)
    request.httpMethod = "GET"
    request.setValue(key, forHTTPHeaderField: "xi-api-key")
    return request
  }

  /// A key restricted to some endpoints (say Speech to Text only) can't read `/v1/user`: ElevenLabs answers
  /// `missing_permissions` instead of `invalid_api_key`, which still proves the key works.
  public static func result(status: Int, body: Data) -> KeyCheckResult {
    if (200..<300).contains(status) { return .connected }
    let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    let code = (object?["detail"] as? [String: Any])?["status"] as? String
    if code == "missing_permissions" { return .connected }
    switch status {
    case 401: return .invalidKey
    case 429: return .failed("ElevenLabs is rate limiting. Try again in a moment.")
    case 500...: return .failed("ElevenLabs is having trouble (HTTP \(status)).")
    default: return .failed("Unexpected response from ElevenLabs (HTTP \(status)).")
    }
  }

  public static func result(error: Error) -> KeyCheckResult {
    .failed("Couldn't reach ElevenLabs: \(error.localizedDescription)")
  }
}

/// System Settings → Keyboard → "Press 🌐 key to" (`com.apple.HIToolbox` `AppleFnUsageType`).
public enum FnUsage: Equatable, Sendable {
  case doNothing, changeInputSource, emojiAndSymbols, dictation, unknown

  public init(rawValue: Int?) {
    switch rawValue {
    case 0?: self = .doNothing
    case 1?: self = .changeInputSource
    case 2?: self = .emojiAndSymbols
    case 3?: self = .dictation
    default: self = .unknown
    }
  }

  /// Anything but "Do Nothing" makes macOS react to the same fn press Glance uses.
  public var conflictsWithDictation: Bool { self != .doNothing }

  public var name: String {
    switch self {
    case .doNothing: "Do Nothing"
    case .changeInputSource: "Change Input Source"
    case .emojiAndSymbols: "Show Emoji & Symbols"
    case .dictation: "Start Dictation"
    case .unknown: "unknown"
    }
  }

  public var advice: String? {
    guard conflictsWithDictation else { return nil }
    let current = self == .unknown ? "may not be set to Do Nothing" : "is set to “\(name)”"
    return "Your 🌐 fn key \(current). Set System Settings → Keyboard → “Press 🌐 key to” → Do Nothing, "
      + "or macOS will also react when you hold it."
  }
}
