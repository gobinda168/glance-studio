import Foundation

/// A connected issue tracker: one MCP server Claude Code has (spec 2026-10-09-tickets-design.md, "Trackers and
/// fetch"), with the tools a read run, a move run and a comment may use.
public struct Tracker: Codable, Equatable, Hashable, Identifiable, Sendable {
  /// Where its tickets come from: Claude's connector (`claude -p` with its tools), or Glance's own sign-in to a Jira
  /// site (spec 2026-10-12-connectors-design.md).
  public enum Kind: String, Codable, Sendable { case claude, glance }

  public var server: String
  public var readTools: [String]
  public var moveTools: [String]
  public var commentTools: [String]
  public var kind: Kind = .claude
  /// `.glance`: the Atlassian site's id and name.
  public var site: String?
  public var siteName: String?

  public var id: String { server }

  public init(server: String, readTools: [String], moveTools: [String], commentTools: [String]) {
    self.server = server
    self.readTools = readTools
    self.moveTools = moveTools
    self.commentTools = commentTools
  }

  /// A Jira site Glance is signed in to: its server is "glance:<site>".
  public static func glance(site: String, name: String) -> Tracker {
    var tracker = Tracker(server: "glance:" + site, readTools: [], moveTools: [], commentTools: [])
    tracker.kind = .glance
    tracker.site = site
    tracker.siteName = name
    return tracker
  }

  public static func siteID(fromServer server: String) -> String? {
    server.hasPrefix("glance:") ? String(server.dropFirst("glance:".count)) : nil
  }

  enum CodingKeys: String, CodingKey { case server, readTools, moveTools, commentTools, kind, site, siteName }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    server = try c.decode(String.self, forKey: .server)
    readTools = try c.decodeIfPresent([String].self, forKey: .readTools) ?? []
    moveTools = try c.decodeIfPresent([String].self, forKey: .moveTools) ?? []
    commentTools = try c.decodeIfPresent([String].self, forKey: .commentTools) ?? []
    kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .claude
    site = try c.decodeIfPresent(String.self, forKey: .site)
    siteName = try c.decodeIfPresent(String.self, forKey: .siteName)
  }

  /// "Jira", "Linear", "GitHub", else the server's own name without claude.ai's prefix; a Glance site's own name.
  public var name: String {
    if kind == .glance { return siteName ?? "Jira" }
    let lower = server.lowercased()
    if lower.contains("atlassian") || lower.contains("jira") { return "Jira" }
    if lower.contains("linear") { return "Linear" }
    if lower.contains("github") { return "GitHub" }
    return server.hasPrefix("claude.ai ") ? String(server.dropFirst("claude.ai ".count)) : server
  }
}

/// One ticket as a fetch run read it. Status names are the tracker's own; `statusCategory` (Claude's mapping) is what
/// the rules use, so they never depend on a workflow's names.
public struct Ticket: Codable, Equatable, Identifiable, Sendable {
  public enum StatusCategory: String, Codable, CaseIterable, Sendable {
    case todo, inProgress, review, done, unknown

    /// Its place along the workflow; unknown has none (and is never moved on its own).
    public var step: Int? {
      switch self {
      case .todo: 0
      case .inProgress: 1
      case .review: 2
      case .done: 3
      case .unknown: nil
      }
    }

    public var title: String {
      switch self {
      case .todo: "To do"
      case .inProgress: "In progress"
      case .review: "In review"
      case .done: "Done"
      case .unknown: "Other"
      }
    }
  }

  /// Why it's on the list: assigned to the user, unassigned in their sprint (Up next), or their saved query.
  public enum Group: String, Codable, Sendable { case assigned, upNext, query }

  /// A status the ticket can move to now.
  public struct Transition: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var category: StatusCategory

    public init(id: String, name: String, category: StatusCategory) {
      self.id = id
      self.name = name
      self.category = category
    }
  }

  public var tracker: String
  public var key: String
  public var title: String
  public var status: String
  public var statusCategory: StatusCategory
  public var priority: String?
  public var severity: String?
  public var assignee: String?
  public var due: Date?
  public var updated: Date?
  public var url: URL?
  public var sprint: String?
  /// GitHub issues: "owner/name" (their key is "owner/name#88").
  public var repository: String?
  public var transitions: [Transition]
  public var group: Group

  public var id: String { "\(tracker):\(key)" }

  public init(tracker: String, key: String, title: String, status: String, statusCategory: StatusCategory,
              priority: String? = nil, severity: String? = nil, assignee: String? = nil, due: Date? = nil,
              updated: Date? = nil, url: URL? = nil, sprint: String? = nil, repository: String? = nil,
              transitions: [Transition], group: Group) {
    self.tracker = tracker
    self.key = key
    self.title = title
    self.status = status
    self.statusCategory = statusCategory
    self.priority = priority
    self.severity = severity
    self.assignee = assignee
    self.due = due
    self.updated = updated
    self.url = url
    self.sprint = sprint
    self.repository = repository
    self.transitions = transitions
    self.group = group
  }
}

/// A status change Glance made (or the user made from Glance): for Undo and "Done today".
public struct TicketMove: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var ticketID: String
  public var key: String
  public var from: String
  public var fromCategory: Ticket.StatusCategory
  public var to: String
  public var toCategory: Ticket.StatusCategory
  /// The evidence ("PR #412 merged"), or "By you" for a click.
  public var reason: String
  public var auto: Bool
  public var date: Date

  public init(id: String, ticketID: String, key: String, from: String, fromCategory: Ticket.StatusCategory, to: String,
              toCategory: Ticket.StatusCategory, reason: String, auto: Bool, date: Date) {
    self.id = id
    self.ticketID = ticketID
    self.key = key
    self.from = from
    self.fromCategory = fromCategory
    self.to = to
    self.toCategory = toCategory
    self.reason = reason
    self.auto = auto
    self.date = date
  }
}

/// Claude's order for the day (spec "Ranking").
public struct TicketRank: Codable, Equatable, Sendable {
  public struct Line: Codable, Equatable, Sendable {
    public var key: String
    public var reason: String

    public init(key: String, reason: String) {
      self.key = key
      self.reason = reason
    }
  }

  public var order: [Line]
  public var pickUp: [Line]
  public var summary: String
  public var date: Date

  public init(order: [Line], pickUp: [Line], summary: String, date: Date) {
    self.order = order
    self.pickUp = pickUp
    self.summary = summary
    self.date = date
  }
}

/// A Claude Code session that ended today, for the check-in to match to tickets when it named none.
public struct SessionNote: Codable, Equatable, Sendable {
  public var file: String
  public var folder: String?
  public var prompts: [String]
  public var date: Date

  public init(file: String, folder: String?, prompts: [String], date: Date) {
    self.file = file
    self.folder = folder
    self.prompts = prompts
    self.date = date
  }
}

/// Everything Tickets keeps on disk: the last fetch per tracker, the last rank, the moves, the suggestions and when the
/// daily moments last ran.
public struct TicketBook: Codable, Equatable, Sendable {
  public static let keepMoves = 200

  public private(set) var tickets: [Ticket] = []
  /// Tracker server → when its tickets were fetched.
  public private(set) var fetched: [String: Date] = [:]
  public var rank: TicketRank?
  /// Newest first.
  public private(set) var moves: [TicketMove] = []
  public var suggestions = SuggestionState()
  /// Ticket id → when a signal last mentioned it (for staleness).
  public private(set) var activity: [String: Date] = [:]
  /// Today's ended Claude sessions (only the latest day's are kept).
  public private(set) var sessions: [SessionNote] = []
  /// "YYYY-MM-DD" of the last morning card and check-in.
  public var lastMorning: String?
  public var lastCheckIn: String?
  /// When the signals were last scanned; nil before the first scan (which only nudges).
  public var lastScan: Date?

  public init() {}

  /// The tickets of `tracker` become `fetched` (duplicates by key dropped); other trackers' stay.
  public mutating func merge(_ fetched: [Ticket], tracker: String, at date: Date) {
    tickets.removeAll { $0.tracker == tracker }
    var seen = Set<String>()
    tickets += fetched.filter { $0.tracker == tracker && seen.insert($0.id).inserted }
    self.fetched[tracker] = date
  }

  /// Tickets a Claude connector also read from a Jira site Glance reads itself: those not from `keep` whose URL host
  /// is in `hosts` go, so each ticket shows (and moves) once.
  public mutating func dropCovered(hosts: Set<String>, keep: Set<String>) {
    guard !hosts.isEmpty else { return }
    tickets.removeAll { ticket in
      !keep.contains(ticket.tracker) && (ticket.url?.host?.lowercased()).map(hosts.contains) == true
    }
  }

  public func ticket(_ id: String) -> Ticket? { tickets.first { $0.id == id } }

  public mutating func update(_ ticket: Ticket) {
    guard let index = tickets.firstIndex(where: { $0.id == ticket.id }) else { return }
    tickets[index] = ticket
  }

  public mutating func record(_ move: TicketMove) {
    moves.insert(move, at: 0)
    if moves.count > Self.keepMoves { moves.removeLast(moves.count - Self.keepMoves) }
  }

  public func moves(on day: Date, calendar: Calendar) -> [TicketMove] {
    moves.filter { calendar.isDate($0.date, inSameDayAs: day) }
  }

  public mutating func noteActivity(_ ticketID: String, at date: Date) {
    activity[ticketID] = max(activity[ticketID] ?? .distantPast, date)
  }

  /// Records an ended session (replacing one with the same file); sessions from an earlier day than the newest go.
  public mutating func note(_ session: SessionNote, calendar: Calendar = .current) {
    sessions.removeAll { $0.file == session.file }
    sessions.append(session)
    guard let newest = sessions.map(\.date).max() else { return }
    sessions.removeAll { !calendar.isDate($0.date, inSameDayAs: newest) }
  }

  /// The oldest fetch time: what the page's "as of" shows.
  public var asOf: Date? { fetched.values.min() }

  public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

  public static func decode(_ data: Data) -> TicketBook? { try? JSONDecoder().decode(TicketBook.self, from: data) }
}
