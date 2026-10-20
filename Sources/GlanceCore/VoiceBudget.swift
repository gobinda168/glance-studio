/// Decides, paragraph by paragraph, whether the cloud voice can read it. Once a reply falls back to the Mac voice it
/// stays there until the next reply, so the voice never flips back and forth mid-explanation.
public struct VoiceBudget: Equatable, Sendable {
  public enum Choice: Equatable, Sendable {
    case cloud
    case system(TTSFailure)
  }

  /// Characters left this period; nil when unknown (not fetched yet, or a pay-as-you-go provider).
  public private(set) var remaining: Int?
  /// Why this reply is on the Mac voice.
  public private(set) var fallback: TTSFailure?

  public init(remaining: Int? = nil) {
    self.remaining = remaining
  }

  public mutating func setRemaining(_ value: Int?) {
    remaining = value
  }

  public mutating func choose(characters: Int, cached: Bool) -> Choice {
    if cached { return .cloud }
    if let fallback { return .system(fallback) }
    if let remaining, remaining < characters {
      fallback = .quotaExceeded
      return .system(.quotaExceeded)
    }
    return .cloud
  }

  public mutating func spent(_ characters: Int) {
    if let remaining { self.remaining = max(0, remaining - characters) }
  }

  public mutating func failed(_ failure: TTSFailure) {
    fallback = failure
    if failure == .quotaExceeded { remaining = 0 }
  }

  public mutating func newReply() {
    fallback = nil
  }

  /// A different provider, key or voice: nothing known carries over.
  public mutating func reset() {
    remaining = nil
    fallback = nil
  }
}
