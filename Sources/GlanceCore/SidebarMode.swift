import Foundation

/// The icon strip at Glance Studio's left edge: each icon opens its own side bar (spec
/// 2026-10-07-activity-strip-design.md), in the order and with the icons of the PR Management canvas (spec
/// 2026-10-07-pr-manager-design.md).
public enum SidebarMode: String, CaseIterable, Sendable {
  case terminal
  case editor
  /// Browser: saved apps and tabs (spec 2026-10-10-browser-design.md); Chats, Issues and Docs before it.
  case browser
  case agents
  case automations
  case pullRequests
  /// To-dos & Notes: what Ask Claude saved from selected text (spec 2026-10-13-ask-claude-selection-design.md).
  case captures
  /// Tickets: the user's tickets in Claude's daily order (spec 2026-10-09-tickets-design.md).
  case tickets
  /// Journal: the days Glance wrote down, Today and Insights (spec 2026-10-09-journal-design.md).
  case journal
  /// Meetings: recorded meetings, their transcripts and notes (spec 2026-10-09-meeting-notes-design.md).
  case meetings
  /// Usage: Claude Code tokens and their API-rate cost by day, week and month (spec 2026-10-09-token-usage-design.md).
  case usage
  case tools
  /// Mods: the Claude Code mods Glance loads, each with a switch and its settings (spec 2026-10-13-mod-library-design.md).
  case mods
  /// Notifications: the inbox, at the strip's bottom above Settings (spec 2026-10-09-notifications-design.md).
  case notifications
  /// Settings: the strip's bottom icon, not in `stripModes`.
  case settings

  /// The strip's top group, in the canvas's order, without the modes whose feature is off; Notifications and Settings
  /// sit at the bottom.
  public static func stripModes(enabled: Set<Feature>) -> [SidebarMode] {
    allCases.filter { !bottom.contains($0) && $0.isShown(enabled: enabled) }
  }

  /// The strip's bottom group above Settings, without the modes whose feature is off.
  public static func stripBottomModes(enabled: Set<Feature>) -> [SidebarMode] {
    [.notifications].filter { $0.isShown(enabled: enabled) }
  }

  private static let bottom: Set<SidebarMode> = [.notifications, .settings]

  /// The saved choice, or Terminal (the tab list Glance Studio showed before the strip) when there's none or its
  /// feature is off.
  public init(saved: String?, enabled: Set<Feature>) {
    let name = saved.map { Self.replaced[$0] ?? $0 }
    self = name.flatMap(SidebarMode.init(rawValue:)).flatMap { $0.isShown(enabled: enabled) ? $0 : nil } ?? .terminal
  }

  /// The side bars the Browser replaced (2026-10-10): saved as one of them, it comes back as the Browser.
  static let replaced: [String: String] = ["chats": "browser", "issues": "browser", "docs": "browser"]

  /// A strip click opens the item's library full width, with no side bar (spec
  /// 2026-10-14-fullwidth-libraries-design.md): the side bar comes back in an item's own tab.
  public var opensLibrary: Bool {
    self == .automations || self == .agents || self == .mods
  }

  /// The icon's tooltip and the side bar's header, in the canvas's words.
  public var title: String {
    switch self {
    case .notifications: "Notifications"
    case .browser: "Browser"
    case .terminal: "Terminal"
    case .editor: "Editor"
    case .agents: "Agents"
    case .automations: "Automations"
    case .pullRequests: "Pull requests"
    case .captures: "To-dos & Notes"
    case .tickets: "Tickets"
    case .journal: "Journal"
    case .meetings: "Meetings"
    case .usage: "Usage"
    case .tools: "Tools"
    case .mods: "Mods"
    case .settings: "Settings"
    }
  }

  /// The canvas's icon on the strip.
  public var icon: StudioIcons.Name {
    switch self {
    case .notifications: .bell
    case .browser: .globe
    case .terminal: .terminal
    case .editor: .editor
    case .agents: .agents
    case .automations: .automations
    case .pullRequests: .pullRequest
    case .captures: .notes
    case .tickets: .checklist
    case .journal: .journal
    case .meetings: .mic
    case .usage: .chart
    case .tools: .tools
    case .mods: .puzzle
    case .settings: .settings
    }
  }

  /// Whether the side bar exists yet. The others show a placeholder until they're built.
  public var isBuilt: Bool {
    switch self {
    case .notifications, .browser, .terminal, .editor, .agents, .automations, .pullRequests, .captures, .tickets, .journal,
         .meetings, .usage, .tools, .mods, .settings: true
    }
  }

  /// The feature its side bar belongs to (on the strip only while that's on), or nil for the ones every build has.
  public var feature: Feature? {
    switch self {
    case .notifications: .notifications
    case .browser: .browser
    case .agents: .agents
    case .automations: .automations
    case .tools: .tools
    case .journal: .journal
    case .meetings: .meetingNotes
    case .usage: .usage
    case .tickets: .tickets
    case .terminal, .editor, .pullRequests, .captures, .mods, .settings: nil
    }
  }

  /// Whether this build shows it: it has no feature, or its feature is on. Agents run on the automation engine, so
  /// they show only while Automations is on too.
  public func isShown(enabled: Set<Feature>) -> Bool {
    if self == .agents { return enabled.contains(.agents) && enabled.contains(.automations) }
    return feature.map(enabled.contains) ?? true
  }
}
