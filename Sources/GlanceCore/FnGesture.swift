import Foundation

/// Tells holding fn to dictate apart from fn used as a modifier (fn+←, fn+F-keys).
/// Feed it key events and periodic ticks; it answers with what the dictation should do.
public struct FnGesture: Sendable {
  public enum Action: Equatable, Sendable {
    /// fn went down: start capturing locally, send nothing yet.
    case arm
    /// Held long enough with no other key: this is dictation.
    case start
    case commit
    case cancel
    case capWarning
  }

  public static let holdThreshold: TimeInterval = 0.25
  public static let warnAfter: TimeInterval = 110
  public static let cap: TimeInterval = 120

  private enum Phase: Equatable {
    case idle
    case pending(since: TimeInterval)
    case active(since: TimeInterval, warned: Bool)
  }

  private var phase = Phase.idle

  public init() {}

  public var isActive: Bool {
    if case .active = phase { true } else { false }
  }

  public mutating func fnDown(at time: TimeInterval) -> Action? {
    guard phase == .idle else { return nil }
    phase = .pending(since: time)
    return .arm
  }

  public mutating func fnUp(at time: TimeInterval) -> Action? {
    switch phase {
    case .idle: return nil
    case .pending: phase = .idle; return .cancel
    case .active: phase = .idle; return .commit
    }
  }

  /// Any other key or modifier while fn is down means fn is being used as a modifier.
  public mutating func otherKey(at time: TimeInterval) -> Action? {
    guard phase != .idle else { return nil }
    phase = .idle
    return .cancel
  }

  public mutating func tick(at time: TimeInterval) -> Action? {
    switch phase {
    case .idle:
      return nil
    case .pending(let since):
      guard time - since >= Self.holdThreshold else { return nil }
      phase = .active(since: since, warned: false)
      return .start
    case .active(let since, let warned):
      if time - since >= Self.cap {
        phase = .idle
        return .commit
      }
      if !warned, time - since >= Self.warnAfter {
        phase = .active(since: since, warned: true)
        return .capWarning
      }
      return nil
    }
  }

  /// Back to idle without an action, e.g. when dictation can't start. fn must be released before the next hold.
  public mutating func reset() {
    phase = .idle
  }
}
