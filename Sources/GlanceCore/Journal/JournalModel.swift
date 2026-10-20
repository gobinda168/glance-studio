import Foundation

/// What Journal collects from (spec 2026-10-09-journal-design.md, "Capture"); each has its own switch.
public enum JournalSource: String, CaseIterable, Codable, Sendable {
  case claude, git, github, calendar, terminal

  public var title: String {
    switch self {
    case .claude: "Claude Code sessions"
    case .git: "Git commits"
    case .github: "GitHub"
    case .calendar: "Calendar"
    case .terminal: "Terminal history"
    }
  }

  /// The setup page's and Settings' line for it.
  public var detail: String {
    switch self {
    case .claude: "Your Claude Code conversations in ~/.claude/projects: what you asked and which files changed."
    case .git: "Commits you authored in repositories Glance knows about."
    case .github: "Pull requests you opened or merged, and reviews you gave, through gh."
    case .calendar: "Meetings from the calendars ticked in Settings → Meetings."
    case .terminal: "When you ran commands, to estimate time per project. Never written into a recap."
    }
  }
}

/// Text from a collector on its way into the store, or from Claude on its way to the screen.
public enum JournalText {
  /// One line: secrets redacted, whitespace runs collapsed to a space, at most `limit` characters (an ellipsis ends a
  /// cut one).
  public static func clean(_ text: String, limit: Int) -> String {
    let line = SecretFilter.redact(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return cut(line, limit: limit)
  }

  /// Several lines kept as written: trimmed, secrets redacted, at most `limit` characters.
  public static func trim(_ text: String, limit: Int) -> String {
    cut(SecretFilter.redact(text).trimmingCharacters(in: .whitespacesAndNewlines), limit: limit)
  }

  private static func cut(_ text: String, limit: Int) -> String {
    guard text.count > limit else { return text }
    return String(text.prefix(max(0, limit - 1))).trimmingCharacters(in: .whitespaces) + "…"
  }
}

/// ISO 8601 times as Claude Code ("…30.997Z"), git ("…+05:30") and GitHub ("…Z") write them.
public enum JournalTime {
  // ISO8601DateFormatter is thread-safe (Apple's docs), so shared instances are fine from any isolation.
  nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  nonisolated(unsafe) private static let whole: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  public static func parse(_ text: String) -> Date? {
    fractional.date(from: text) ?? whole.date(from: text)
  }
}

/// One thing that happened (spec "Storage", `events`): a Claude Code session's day, a commit, a pull request opened or
/// merged, a review, a meeting, a note.
public struct JournalEvent: Codable, Equatable, Sendable, Identifiable {
  public enum Source: String, CaseIterable, Codable, Sendable {
    case claude, git, pr, review, meeting, note
  }

  public var source: Source
  /// Unique within its source: collecting again updates the event instead of adding one.
  public var externalID: String
  public var day: JournalDay
  public var start: Date
  public var end: Date?
  /// A project folder (a git root), "owner/name" for a pull request with no folder on this Mac, or nil.
  public var project: String?
  public var title: String
  public var detail: JournalDetail

  public init(source: Source, externalID: String, day: JournalDay, start: Date, end: Date? = nil,
              project: String? = nil, title: String, detail: JournalDetail = JournalDetail()) {
    self.source = source
    self.externalID = externalID
    self.day = day
    self.start = start
    self.end = end
    self.project = project
    self.title = title
    self.detail = detail
  }

  /// Stable across collections: "<source>:<externalID>".
  public var id: String { "\(source.rawValue):\(externalID)" }
}

/// What an event carries beyond its title, by source; the rest stay nil.
public struct JournalDetail: Codable, Equatable, Sendable {
  // A Claude Code session's day.
  public var prompts: [String]?
  public var files: [String]?
  public var turns: Int?
  public var activeMinutes: Int?
  public var spans: [JournalSpan]?
  public var branch: String?
  // A commit, a pull request, a review.
  public var hash: String?
  public var filesChanged: Int?
  public var insertions: Int?
  public var deletions: Int?
  public var repository: String?
  public var number: Int?
  public var url: String?
  /// A pull request's event: "opened" or "merged".
  public var action: String?
  /// A review's state, lowercased: "approved", "changes_requested", "commented".
  public var reviewState: String?
  public var comments: Int?
  // A meeting.
  public var calendar: String?
  /// Its recorded notes: the overview and the user's action items (Meeting Notes).
  public var notes: String?

  public init(prompts: [String]? = nil, files: [String]? = nil, turns: Int? = nil, activeMinutes: Int? = nil,
              spans: [JournalSpan]? = nil, branch: String? = nil, hash: String? = nil, filesChanged: Int? = nil,
              insertions: Int? = nil, deletions: Int? = nil, repository: String? = nil, number: Int? = nil,
              url: String? = nil, action: String? = nil, reviewState: String? = nil, comments: Int? = nil,
              calendar: String? = nil, notes: String? = nil) {
    self.prompts = prompts
    self.files = files
    self.turns = turns
    self.activeMinutes = activeMinutes
    self.spans = spans
    self.branch = branch
    self.hash = hash
    self.filesChanged = filesChanged
    self.insertions = insertions
    self.deletions = deletions
    self.repository = repository
    self.number = number
    self.url = url
    self.action = action
    self.reviewState = reviewState
    self.comments = comments
    self.calendar = calendar
    self.notes = notes
  }
}

/// An accomplishment (spec "Storage", `entries`): what was done, with its story, the raw material for posts later.
public struct JournalEntry: Codable, Equatable, Sendable, Identifiable {
  public enum Kind: String, CaseIterable, Codable, Sendable {
    case shipped, fixed, reviewed, designed, learned, meeting, other

    public var title: String { rawValue.capitalized }
  }

  public var id: String
  public var day: JournalDay
  public var position: Int
  public var title: String
  public var summary: String
  public var project: String?
  public var kind: Kind
  /// A measured result ("worker startup 292 s → 40 s"), or empty.
  public var impact: String
  public var challenge: String
  public var approach: String
  public var outcome: String
  public var lesson: String
  /// Lowercase tags ("performance", "ai").
  public var skills: [String]
  public var minutes: Int
  public var highlight: Bool
  /// The same accomplishment without employer, customer, repository or people's names (stage 3 publishes it).
  public var publicDraft: String
  /// The events it came from (`JournalEvent.id`).
  public var eventIDs: [String]
  /// The user changed it, or added it: a redraft keeps it.
  public var edited: Bool
  public var createdAt: Date
  public var updatedAt: Date

  public init(id: String = UUID().uuidString, day: JournalDay, position: Int = 0, title: String, summary: String = "",
              project: String? = nil, kind: Kind = .other, impact: String = "", challenge: String = "",
              approach: String = "", outcome: String = "", lesson: String = "", skills: [String] = [],
              minutes: Int = 0, highlight: Bool = false, publicDraft: String = "", eventIDs: [String] = [],
              edited: Bool = false, createdAt: Date, updatedAt: Date? = nil) {
    self.id = id
    self.day = day
    self.position = position
    self.title = title
    self.summary = summary
    self.project = project
    self.kind = kind
    self.impact = impact
    self.challenge = challenge
    self.approach = approach
    self.outcome = outcome
    self.lesson = lesson
    self.skills = skills
    self.minutes = minutes
    self.highlight = highlight
    self.publicDraft = publicDraft
    self.eventIDs = eventIDs
    self.edited = edited
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
  }
}

/// A day's recap and bookkeeping (spec "Storage", `days`).
public struct JournalDayRecord: Codable, Equatable, Sendable {
  public enum Status: String, CaseIterable, Codable, Sendable {
    case open, drafted, reviewed, failed
  }

  public var day: JournalDay
  public var status: Status
  public var headline: String
  public var recap: String
  /// Claude's estimate per project, used only for a day with no timestamped activity.
  public var minutesByProject: [String: Int]
  public var generatedAt: Date?
  public var reviewedAt: Date?
  public var error: String?
  /// The sources that collected nothing, and why ("GitHub" → "signed out").
  public var sourceNotes: [String: String]
  /// Terminal activity per project, for the time figures only.
  public var terminal: [String: [JournalSpan]]

  public init(day: JournalDay, status: Status = .open, headline: String = "", recap: String = "",
              minutesByProject: [String: Int] = [:], generatedAt: Date? = nil, reviewedAt: Date? = nil,
              error: String? = nil, sourceNotes: [String: String] = [:], terminal: [String: [JournalSpan]] = [:]) {
    self.day = day
    self.status = status
    self.headline = headline
    self.recap = recap
    self.minutesByProject = minutesByProject
    self.generatedAt = generatedAt
    self.reviewedAt = reviewedAt
    self.error = error
    self.sourceNotes = sourceNotes
    self.terminal = terminal
  }
}

/// A day as the side bar lists it.
public struct JournalDaySummary: Equatable, Sendable, Identifiable {
  public let day: JournalDay
  public let status: JournalDayRecord.Status
  public let headline: String
  public let eventCount: Int
  public let entryCount: Int
  /// Events first collected after the recap was drafted.
  public let newSinceRecap: Int

  public init(day: JournalDay, status: JournalDayRecord.Status, headline: String, eventCount: Int, entryCount: Int,
              newSinceRecap: Int) {
    self.day = day
    self.status = status
    self.headline = headline
    self.eventCount = eventCount
    self.entryCount = entryCount
    self.newSinceRecap = newSinceRecap
  }

  public var id: JournalDay { day }
}
