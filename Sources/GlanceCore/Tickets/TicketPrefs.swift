import Foundation

/// What tells Glance a ticket's status is out of date (spec "Signals, suggestions, policy").
public enum TicketSignal: String, Codable, CaseIterable, Sendable {
  case git, prOpened, prMerged, session, stale, checkIn

  /// Settings' row name.
  public var title: String {
    switch self {
    case .git: "Commits and branches"
    case .prOpened: "Pull request opened"
    case .prMerged: "Pull request merged"
    case .session: "Claude sessions"
    case .stale: "No activity for a while"
    case .checkIn: "End-of-day check-in"
    }
  }

  /// Whether Auto is allowed: staleness and the check-in always ask.
  public var canAuto: Bool { self != .stale && self != .checkIn }
}

extension TicketSignal: CodingKeyRepresentable {}

/// Settings → Tickets (spec "Settings → Tickets"). Every field decodes when missing, so older saved prefs keep working.
public struct TicketPrefs: Codable, Equatable, Sendable {
  public enum Mode: String, Codable, CaseIterable, Sendable { case auto, nudge, off }

  public static let defaultMorning = 9 * 60
  public static let defaultCheckIn = 18 * 60

  public var modes: [TicketSignal: Mode] = [:]
  public var staleDays = 3
  /// Leave a comment on the ticket when Glance moves it.
  public var comment = false
  /// The user's ordering instructions; empty means the default.
  public var rankingPrompt = ""
  /// Tracker server → the user's query (JQL, a view); empty or missing means the default set.
  public var queries: [String: String] = [:]
  public var trackersOff: Set<String> = []
  /// Minutes after midnight.
  public var morningMinutes = TicketPrefs.defaultMorning
  /// True: exactly at the time; false: at the first activity after it.
  public var morningFixed = false
  public var checkIn = true
  public var checkInMinutes = TicketPrefs.defaultCheckIn
  public var readAloud = false

  public init() {}

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = TicketPrefs()
    modes = try c.decodeIfPresent([TicketSignal: Mode].self, forKey: .modes) ?? d.modes
    staleDays = try c.decodeIfPresent(Int.self, forKey: .staleDays) ?? d.staleDays
    comment = try c.decodeIfPresent(Bool.self, forKey: .comment) ?? d.comment
    rankingPrompt = try c.decodeIfPresent(String.self, forKey: .rankingPrompt) ?? d.rankingPrompt
    queries = try c.decodeIfPresent([String: String].self, forKey: .queries) ?? d.queries
    trackersOff = try c.decodeIfPresent(Set<String>.self, forKey: .trackersOff) ?? d.trackersOff
    morningMinutes = try c.decodeIfPresent(Int.self, forKey: .morningMinutes) ?? d.morningMinutes
    morningFixed = try c.decodeIfPresent(Bool.self, forKey: .morningFixed) ?? d.morningFixed
    checkIn = try c.decodeIfPresent(Bool.self, forKey: .checkIn) ?? d.checkIn
    checkInMinutes = try c.decodeIfPresent(Int.self, forKey: .checkInMinutes) ?? d.checkInMinutes
    readAloud = try c.decodeIfPresent(Bool.self, forKey: .readAloud) ?? d.readAloud
  }

  public static func defaultMode(_ signal: TicketSignal) -> Mode {
    switch signal {
    case .git, .prOpened, .prMerged: .auto
    case .session, .stale, .checkIn: .nudge
    }
  }

  public func mode(_ signal: TicketSignal) -> Mode {
    let mode = modes[signal] ?? Self.defaultMode(signal)
    return mode == .auto && !signal.canAuto ? .nudge : mode
  }

  public mutating func set(_ signal: TicketSignal, _ mode: Mode) {
    modes[signal] = mode == .auto && !signal.canAuto ? .nudge : mode
  }

  public func query(for tracker: String) -> String? {
    let query = queries[tracker]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return query.isEmpty ? nil : query
  }
}
