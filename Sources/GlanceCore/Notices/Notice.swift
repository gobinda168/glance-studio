import Foundation

/// One thing that wants the user's attention (spec 2026-10-09-notifications-design.md): a Slack message, a GitHub
/// notification, a meeting starting, a Claude session waiting. The inbox folds notices by `threadKey`.
public struct Notice: Codable, Equatable, Identifiable, Sendable {
  public enum Source: String, Codable, CaseIterable, Sendable {
    case slack, github, meeting, claude, tickets, automations

    public var title: String {
      switch self {
      case .slack: "Slack"
      case .github: "GitHub"
      case .meeting: "Meetings"
      case .claude: "Claude"
      case .tickets: "Tickets"
      case .automations: "Automations"
      }
    }
  }

  public enum Kind: String, Codable, CaseIterable, Sendable {
    case slackDM, slackMention, slackThread, slackChannel
    case githubReviewRequested, githubMention, githubComment, githubAssigned, githubCIFailed, githubStateChanged,
      githubOther
    case meetingStarting
    case claudeNeedsInput, claudeFinished, terminalAlert, claudeMessage
    case ticketSuggestion, ticketMoved, ticketFailed, ticketsMorning, ticketsCheckIn
    case automationApproval, automationFailed

    public var source: Source {
      switch self {
      case .slackDM, .slackMention, .slackThread, .slackChannel: .slack
      case .githubReviewRequested, .githubMention, .githubComment, .githubAssigned, .githubCIFailed,
        .githubStateChanged, .githubOther: .github
      case .meetingStarting: .meeting
      case .claudeNeedsInput, .claudeFinished, .terminalAlert, .claudeMessage: .claude
      case .ticketSuggestion, .ticketMoved, .ticketFailed, .ticketsMorning, .ticketsCheckIn: .tickets
      case .automationApproval, .automationFailed: .automations
      }
    }

    /// Settings' row name and the place line's fallback.
    public var label: String {
      switch self {
      case .slackDM: "Direct messages"
      case .slackMention: "Mentions"
      case .slackThread: "Threads I'm in"
      case .slackChannel: "Channel messages"
      case .githubReviewRequested: "Review requested"
      case .githubMention: "Mentions"
      case .githubComment: "Comments on my pull requests"
      case .githubAssigned: "Assigned to me"
      case .githubCIFailed: "Checks failed"
      case .githubStateChanged: "Merged or closed"
      case .githubOther: "Everything else"
      case .meetingStarting: "Meeting starting"
      case .claudeNeedsInput: "Claude needs input"
      case .claudeFinished: "Claude finished"
      case .terminalAlert: "Terminal alerts"
      case .claudeMessage: "Messages from Claude sessions"
      case .ticketSuggestion: "Status suggestions"
      case .ticketMoved: "Moves Glance made"
      case .ticketFailed: "Failed updates"
      case .ticketsMorning: "Morning top 3"
      case .ticketsCheckIn: "End-of-day check-in"
      case .automationApproval: "Waiting for approval"
      case .automationFailed: "Failed runs"
      }
    }

    /// Someone asked the user directly: the page's "Needs you" section and the strip badge.
    public var needsYou: Bool {
      switch self {
      case .slackDM, .slackMention, .githubReviewRequested, .githubMention, .githubAssigned, .githubCIFailed,
        .claudeNeedsInput, .meetingStarting, .ticketSuggestion, .ticketFailed, .automationApproval,
        .automationFailed: true
      default: false
      }
    }

    public static func kinds(of source: Source) -> [Kind] { allCases.filter { $0.source == source } }
  }

  public enum State: String, Codable, Sendable { case unread, read, done }

  /// Where Open goes.
  public enum Target: Codable, Equatable, Sendable {
    case pullRequest(repository: String, number: Int, path: String?, line: Int?)
    case issue(repository: String, number: Int)
    case slack(team: String, notificationID: String?, channel: String?)
    case terminal(surface: String?, cwd: String?)
    case meeting(eventID: String, joinURL: URL?)
    /// A web page (a ticket): opened in the default browser.
    case link(URL)
    case none
  }

  public var id: String
  public var source: Source
  public var kind: Kind
  public var title: String
  public var place: String?
  public var preview: String
  public var date: Date
  public var threadKey: String
  public var target: Target
  public var state: State
  public var people: [String]
  public var avatarURL: URL?
  public var meta: [String: String]

  /// A button a source puts on its notices (Tickets: "Move to Done", "Not now"); the hub hands its id back.
  public struct Action: Codable, Equatable, Sendable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
      self.id = id
      self.title = title
    }
  }

  /// Buttons in place of Reply/Open on the card and the row; `moreActions` go in its ⋯ menu. nil for most sources.
  public var actions: [Action]?
  public var moreActions: [Action]?

  public init(id: String, source: Source, kind: Kind, title: String, place: String?, preview: String, date: Date,
              threadKey: String, target: Target, state: State = .unread, people: [String] = [],
              avatarURL: URL? = nil, meta: [String: String] = [:], actions: [Action]? = nil,
              moreActions: [Action]? = nil) {
    self.id = id
    self.source = source
    self.kind = kind
    self.title = title
    self.place = place
    self.preview = Notice.previewLine(preview)
    self.date = date
    self.threadKey = threadKey
    self.target = target
    self.state = state
    self.people = people
    self.avatarURL = avatarURL
    self.meta = meta
    self.actions = actions
    self.moreActions = moreActions
  }

  /// One line: whitespace runs collapsed, trimmed, at most 280 characters.
  public static func previewLine(_ text: String) -> String {
    let line = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    return String(line.prefix(280))
  }
}

/// How a source is doing, for the page's chips and Settings.
public enum SourceStatus: Equatable, Sendable {
  case off
  case running
  case paused(String)
}
