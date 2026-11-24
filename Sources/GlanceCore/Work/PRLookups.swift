import Foundation

/// Which branch the board asks `gh` about next. One lookup per repository and branch, a minute apart while a session
/// on it is live and ten once all have ended. The board asks again each time a lookup finishes, so a quiet board still
/// works through every branch.
public enum PRLookups {
  public static let liveInterval: TimeInterval = 60
  public static let endedInterval: TimeInterval = 600

  public struct Candidate: Equatable, Sendable {
    public var key: String
    public var live: Bool
    public init(key: String, live: Bool) { self.key = key; self.live = live }
  }

  /// The first branch, in board order, that has not been looked up within its interval; nil when none is due. A branch
  /// several sessions share is one lookup, at the live rate if any of them is live. The caller records `now` for the
  /// key it takes, whether the lookup then works or fails, so a failure is retried at the normal rate.
  public static func next(_ candidates: [Candidate], looked: [String: Date], now: Date) -> Candidate? {
    var order: [String] = []
    var live: [String: Bool] = [:]
    for candidate in candidates {
      if live[candidate.key] == nil { order.append(candidate.key) }
      live[candidate.key] = (live[candidate.key] ?? false) || candidate.live
    }
    for key in order {
      let isLive = live[key] ?? false
      let interval = isLive ? liveInterval : endedInterval
      if let last = looked[key], now.timeIntervalSince(last) < interval { continue }
      return Candidate(key: key, live: isLive)
    }
    return nil
  }
}
