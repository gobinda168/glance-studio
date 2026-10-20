import Foundation

/// Strip switching (spec 2026-10-11-strip-switching-design.md): which strip item a tab belongs to, and each window's
/// memory of the tab last in front for each item.
extension SidebarMode {
  /// The strip item whose side bar lists a tab of `kind` (the tab controller's `tabKind`; nil for a terminal tab),
  /// or nil for a kind no item owns. Home belongs to Terminal, whose side bar pins it.
  public static func owner(ofTabKind kind: String?) -> SidebarMode? {
    guard let kind else { return .terminal }
    switch kind {
    case "home": return .terminal
    case "razor", "studio", "editorStart": return .editor
    case "browser": return .browser
    case "pullRequest", "newPullRequest", "reviewInbox": return .pullRequests
    case "automation", "automationBuilder", "automationsLibrary": return .automations
    case "agentsLibrary": return .agents
    case "captures": return .captures
    case "mods": return .mods
    case "tickets": return .tickets
    case "journal": return .journal
    case "meetings": return .meetings
    case "usage": return .usage
    case "notifications": return .notifications
    case "settings": return .settings
    default: return nil
    }
  }
}

/// One window's memory: the tab last in front for each strip item, and the order tabs were in front.
public struct StripMemory<Tab: Hashable & Sendable>: Sendable {
  private var lastByMode: [SidebarMode: Tab] = [:]
  /// Tabs in the order they were last in front, the latest last.
  private var order: [Tab] = []

  public init() {}

  /// `tab` came to the front; `mode` is the strip item it's remembered for (nil: ordered only, as Home is).
  public mutating func recordFront(_ tab: Tab, mode: SidebarMode?) {
    order.removeAll { $0 == tab }
    order.append(tab)
    if let mode { lastByMode[mode] = tab }
  }

  /// The tab a click on `mode` goes back to, among `candidates` (that item's open tabs, in tab order): the remembered
  /// one while it's open, else the one in front most recently, else the last in order; nil with none.
  public func last(for mode: SidebarMode, candidates: [Tab]) -> Tab? {
    if let tab = lastByMode[mode], candidates.contains(tab) { return tab }
    return mostRecent(of: candidates) ?? candidates.last
  }

  /// Of `tabs`, the one in front most recently, or nil when none has been.
  public func mostRecent(of tabs: [Tab]) -> Tab? {
    let wanted = Set(tabs)
    return order.last(where: wanted.contains)
  }
}
