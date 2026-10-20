import Foundation

/// Keeps the plan usage shown steady while several Claude Code sessions write `usage.json`. Each session's payload is
/// its own last snapshot, so an idle session can write numbers older (lower) than another's: within one window the
/// percentage only goes up, and a window with a later reset replaces the old one.
public struct UsageTracker {
  public typealias Reading = (usage: PlanUsage, updated: Date)

  /// Resets this close together are the same window.
  private static let sameWindow: TimeInterval = 60

  private var current: Reading?

  public init() {}

  /// What `usage.json` holds now (nil: no file, or nothing left in it). Returns what to show, and when it last changed.
  public mutating func update(_ loaded: Reading?, now: Date) -> Reading? {
    guard let loaded else {
      current = nil
      return nil
    }
    let kept = current?.usage
    let merged = PlanUsage(
      fiveHour: Self.merge(Self.live(kept?.fiveHour, now: now), loaded.usage.fiveHour),
      sevenDay: Self.merge(Self.live(kept?.sevenDay, now: now), loaded.usage.sevenDay))
    if let current, current.usage == merged { return current }
    current = (merged, loaded.updated)
    return current
  }

  private static func live(_ window: PlanUsage.Window?, now: Date) -> PlanUsage.Window? {
    guard let window, window.resetsAt > now else { return nil }
    return window
  }

  private static func merge(_ old: PlanUsage.Window?, _ new: PlanUsage.Window?) -> PlanUsage.Window? {
    guard let old else { return new }
    guard let new else { return old }
    if new.resetsAt > old.resetsAt.addingTimeInterval(sameWindow) { return new }
    if new.resetsAt < old.resetsAt.addingTimeInterval(-sameWindow) { return old }
    return PlanUsage.Window(percent: max(old.percent, new.percent), resetsAt: old.resetsAt)
  }
}
