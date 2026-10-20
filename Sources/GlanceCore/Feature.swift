import Foundation

/// A part of Glance Studio that ships once it's GA (2026-10-09). Until then a release build (scripts/release.sh) leaves
/// it out, and a development build has it unless it's switched off in the Develop menu.
public enum Feature: String, CaseIterable, Sendable {
  /// Browser: saved apps (Slack, Jira, Confluence, any site) and tabs, later dev servers, meetings and Claude (spec
  /// 2026-10-10-browser-design.md). It replaced Chats and Jira & Confluence.
  case browser
  /// Agents: automations whose steps are Claude with tools and that stop to ask you (spec
  /// 2026-10-10-agents-design.md). Needs Automations.
  case agents
  case automations
  case tools
  case journal
  case cloud
  /// Notifications: one inbox for Slack, GitHub, meetings and Claude (spec 2026-10-09-notifications-design.md).
  case notifications
  /// Usage: Claude Code tokens and their API-rate cost (spec 2026-10-09-token-usage-design.md).
  case usage
  /// Meeting notes: record a call, transcribe it on this Mac, notes by Claude (spec 2026-10-09-meeting-notes-design.md).
  case meetingNotes
  /// Tickets: the user's tickets ranked daily, statuses kept honest (spec 2026-10-09-tickets-design.md).
  case tickets
  /// Orb channel: Claude sessions reach the user through the orb, cards and voice (spec 2026-10-09-orb-channel-design.md).
  case orbChannel
  /// Claude needs you: the orb glows and a card answers a Studio split's permission, question or plan prompt (spec 2026-10-11-needs-input-orb-design.md).
  case needsYou
  /// Secrets: tokens Claude can use but never see (spec 2026-10-10-secrets-broker-design.md).
  case secrets
  /// Tab groups: named, foldable groups of terminal tabs in the Terminal side bar (spec
  /// 2026-10-11-tab-groups-design.md).
  case tabGroups
  /// Summaries: per-session transcript summaries and the Glance Humanize style (spec
  /// 2026-10-11-humanize-summaries-design.md).
  case summaries
  /// GS Code: the VS Code editor kind and its download, beside Razor Code (spec 2026-10-06-vscode-editor-tab-design.md).
  /// Off, every editor tab is Razor Code.
  case gsCode

  /// Generally available: in every build, and off the Develop menu. Move a feature to `true` when it's ready. All of
  /// them went GA for the release build on 2026-10-10; a new unpolished feature starts at `false`.
  public var isGA: Bool {
    switch self {
    case .browser, .agents, .automations, .tools, .journal, .cloud, .notifications, .usage, .meetingNotes, .tickets,
         .orbChannel, .needsYou, .secrets, .tabGroups, .summaries: true
    case .gsCode: false
    }
  }

  /// Its name in the Develop menu.
  public var title: String {
    switch self {
    case .browser: "Browser"
    case .agents: "Agents"
    case .automations: "Automations"
    case .tools: "Tools"
    case .journal: "Journal"
    case .cloud: "Glance Cloud"
    case .notifications: "Notifications"
    case .usage: "Usage"
    case .meetingNotes: "Meeting Notes"
    case .tickets: "Tickets"
    case .orbChannel: "Orb Channel"
    case .needsYou: "Claude Needs You"
    case .secrets: "Secrets"
    case .tabGroups: "Tab Groups"
    case .summaries: "Summaries"
    case .gsCode: "GS Code"
    }
  }

  /// What the Develop menu switches: the features not GA yet.
  public static var unreleased: [Feature] { allCases.filter { !$0.isGA } }

  /// The Develop menu's saved switches (`featureChoices`: raw value → Bool). A switch saved for Chats or Jira &
  /// Confluence, before both became the Browser (2026-10-10), counts for the Browser unless it has its own; Chats first.
  public static func choices(saved: [String: Any]) -> [Feature: Bool] {
    var choices: [Feature: Bool] = [:]
    for (key, value) in saved {
      if let feature = Feature(rawValue: key), let on = value as? Bool { choices[feature] = on }
    }
    if choices[.browser] == nil, let on = (saved["chats"] as? Bool) ?? (saved["atlassian"] as? Bool) {
      choices[.browser] = on
    }
    return choices
  }

  /// The features this build has. `choices` are the Develop menu's switches (false is off); only a development build
  /// follows them.
  public static func enabled(development: Bool, choices: [Feature: Bool]) -> Set<Feature> {
    Set(allCases.filter { isOn(isGA: $0.isGA, development: development, choice: choices[$0]) })
  }

  /// A GA feature is on in every build; any other only in a development build, and there unless it was switched off.
  static func isOn(isGA: Bool, development: Bool, choice: Bool?) -> Bool {
    isGA || (development && choice != false)
  }
}
