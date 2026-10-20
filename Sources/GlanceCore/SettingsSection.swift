import Foundation

/// Settings' sections (spec 2026-10-08-settings-design.md), in the side bar's order: each with its title, the line
/// under the page's title, its icon, and whether its page has a live preview beside the rows.
public enum SettingsSection: String, CaseIterable, Sendable {
  case account, connectors, general, terminal, suggestions, voice, dictation, editor, overlay, meetings, browser, notifications, orbChannel,
    secrets, tickets, journal

  /// The section shown last, else General.
  public init(saved: String?) {
    self = saved.flatMap { SettingsSection(rawValue: $0 == "atlassian" ? "browser" : $0) } ?? .general
  }

  public var title: String {
    switch self {
    case .account: "Account"
    case .connectors: "Connectors"
    case .general: "General"
    case .terminal: "Terminal"
    case .suggestions: "Suggestions"
    case .voice: "Voice"
    case .dictation: "Dictation"
    case .editor: "Editor"
    case .overlay: "Overlay"
    case .meetings: "Meetings"
    case .browser: "Browser"
    case .notifications: "Notifications"
    case .orbChannel: "Orb Channel"
    case .secrets: "Secrets"
    case .tickets: "Tickets"
    case .journal: "Journal"
    }
  }

  /// The muted line under the page's title.
  public var line: String {
    switch self {
    case .account: "Your Glance account, for cloud features."
    case .connectors: "What Tickets and Claude can reach."
    case .general: "What runs, and what opens at launch."
    case .terminal: "The terminal's font, colours and cursor."
    case .suggestions: "Completions, history and fixes in the terminal."
    case .voice: "How Glance reads Claude's replies aloud."
    case .dictation: "Hold fn to speak instead of typing."
    case .editor: "What a new editor tab opens."
    case .overlay: "Glance over other terminals and code editors."
    case .meetings: "A nudge before each meeting, with Join."
    case .browser: "Search, history and site data."
    case .notifications: "What lands in your inbox, and what nudges you."
    case .orbChannel: "Claude reaching you through the orb, cards and voice."
    case .secrets: "Tokens Claude can use but never see."
    case .tickets: "Your trackers, the daily order, and status updates."
    case .journal: "Your day, written down: what's collected and when the recap is drafted."
    }
  }

  public var icon: StudioIcons.Name {
    switch self {
    case .account: .person
    case .connectors: .plug
    case .general: .window
    case .terminal: .terminal
    case .suggestions: .suggest
    case .voice: .speaker
    case .dictation: .mic
    case .editor: .editor
    case .overlay: .layers
    case .meetings: .clock
    case .browser: .globe
    case .notifications: .bell
    case .orbChannel: .reply
    case .secrets: .lock
    case .tickets: .checklist
    case .journal: .journal
    }
  }

  /// The page shows a live preview beside its rows (Terminal, Voice, Dictation); the others use the full width.
  public var hasPreview: Bool {
    switch self {
    case .terminal, .voice, .dictation: true
    case .account, .connectors, .general, .suggestions, .editor, .overlay, .meetings, .browser, .notifications, .orbChannel, .secrets,
      .tickets, .journal:
      false
    }
  }

  /// The feature its section belongs to (listed only while that's on), or nil for the ones every build has.
  public var feature: Feature? {
    switch self {
    case .journal: .journal
    case .notifications: .notifications
    case .orbChannel: .orbChannel
    case .secrets: .secrets
    case .tickets: .tickets
    case .browser: .browser
    case .account: .cloud
    default: nil
    }
  }

  public func isShown(enabled: Set<Feature>) -> Bool {
    feature.map(enabled.contains) ?? true
  }
}
