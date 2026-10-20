import Foundation

/// Which automations have a tab open, and the manual runs waiting in one (spec 2026-10-09-automations-design.md,
/// "Approvals": "Manual runs from the tab show the same approval inline instead of a card"). When an automation's
/// last tab closes, its waiting runs get their cards after all, so no approval is left where nobody sees it.
public struct AutomationInlineBook: Equatable, Sendable {
  /// Open automation tabs, by automation id (one per window).
  public private(set) var tabs: [String: Int] = [:]
  /// Parked runs whose approval shows in a tab instead of on a card.
  public private(set) var waiting: Set<AutomationRunRef> = []

  public init() {}

  public mutating func opened(_ id: String) {
    tabs[id, default: 0] += 1
  }

  /// One of `id`'s tabs closed. When it was the last: the runs that now need their cards.
  public mutating func closed(_ id: String) -> [AutomationRunRef] {
    let count = (tabs[id] ?? 0) - 1
    tabs[id] = count > 0 ? count : nil
    guard count <= 0 else { return [] }
    let cards = waiting.filter { $0.automation == id }.sorted { $0.description < $1.description }
    waiting.subtract(cards)
    return cards
  }

  /// A run parked at an outward step: true when its tab shows the approval (a manual run of an automation with a
  /// tab open), so no card goes out.
  public mutating func parked(_ ref: AutomationRunRef, manual: Bool) -> Bool {
    guard manual, tabs[ref.automation] != nil else { return false }
    waiting.insert(ref)
    return true
  }

  /// Answered, or ended.
  public mutating func settled(_ ref: AutomationRunRef) {
    waiting.remove(ref)
  }
}
