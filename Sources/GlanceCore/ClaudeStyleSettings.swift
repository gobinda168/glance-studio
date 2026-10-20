/// When Glance Studio summarizes a Claude Code session (spec 2026-10-11-humanize-summaries-design.md, "Settings").
/// It decides when tokens are spent, not only what's shown.
public enum SummaryMode: String, CaseIterable, Sendable {
  /// Only when the user clicks Summarize. The default: no background token use.
  case manual
  /// The first time a session's summary is opened, then reused until the user refreshes it.
  case oncePerSession
  /// Kept current as Claude works: after a turn ends and a quiet minute.
  case always

  public static let defaultMode = SummaryMode.manual

  /// The saved choice; anything missing or unknown is the default.
  public init(stored: String?) {
    self = stored.flatMap(SummaryMode.init(rawValue:)) ?? .defaultMode
  }

  public var name: String {
    switch self {
    case .manual: "Manual"
    case .oncePerSession: "Once per session"
    case .always: "Always"
    }
  }

  /// Settings' line under the picker.
  public var detail: String {
    switch self {
    case .manual: "Only when you click Summarize. No background token use."
    case .oncePerSession: "The first time you open a session's summary, then reused until you refresh."
    case .always: "Kept current as Claude works, at most once per finished turn after a short pause. Uses the most tokens."
    }
  }
}

/// How Claude talks across Glance Studio (spec 2026-10-11-humanize-summaries-design.md, "Glance Humanize").
public enum ResponseStyle: String, CaseIterable, Sendable {
  /// Claude's own voice: Studio adds nothing.
  case claudeDefault
  /// Glance Humanize (styles/humanize.md): outcome first, plain words, diagrams when they help.
  case humanize

  public static let defaultStyle = ResponseStyle.claudeDefault

  /// The saved choice; anything missing or unknown is the default.
  public init(stored: String?) {
    self = stored.flatMap(ResponseStyle.init(rawValue:)) ?? .defaultStyle
  }

  public var name: String {
    switch self {
    case .claudeDefault: "Claude Default"
    case .humanize: "Glance Humanize"
    }
  }

  /// Settings' line under the picker. The forced plugin style beats an output style picked with /output-style
  /// (spike 2026-10-11), so Humanize says so.
  public var detail: String {
    switch self {
    case .claudeDefault: "Claude's own voice. Nothing added."
    case .humanize: "Outcome first, plain language, diagrams when they help. Same tools and permissions. "
      + "Applies to new Claude sessions. It replaces an output style you picked with /output-style."
    }
  }
}
