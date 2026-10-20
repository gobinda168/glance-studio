import Foundation

/// A calendar event as the meeting nudges see it (spec 2026-10-08-meeting-nudges-design.md, "MeetingAgenda"). Each
/// occurrence of a repeating meeting has its own `id`.
public struct MeetingEvent: Equatable, Sendable, Codable {
  public let id: String
  public let calendarID: String
  public let calendarTitle: String
  public let title: String
  public let start: Date
  public let end: Date
  public let isAllDay: Bool
  /// Declined by the user, or cancelled.
  public let declined: Bool
  public let link: MeetingLink?
  /// The event's iCalendar UID (Google: the event's iCalUID), to find it in Google Calendar.
  public let iCalUID: String?

  public init(id: String, calendarID: String, calendarTitle: String, title: String, start: Date, end: Date,
              isAllDay: Bool, declined: Bool, link: MeetingLink?, iCalUID: String? = nil) {
    self.id = id
    self.calendarID = calendarID
    self.calendarTitle = calendarTitle
    self.title = title
    self.start = start
    self.end = end
    self.isAllDay = isAllDay
    self.declined = declined
    self.link = link
    self.iCalUID = iCalUID
  }

  /// The event's identifier and this occurrence's start.
  public static func occurrenceID(eventID: String, start: Date) -> String {
    "\(eventID)@\(Int(start.timeIntervalSince1970))"
  }
}

/// Which meeting to nudge about, and when to look again: from the start until start + 10 min, unless it was joined,
/// declined or closed.
public enum MeetingAgenda {
  public static let cutoff: TimeInterval = 10 * 60

  public struct Settings: Equatable, Sendable {
    public var calendarsOff: Set<String>

    public init(calendarsOff: Set<String>) {
      self.calendarsOff = calendarsOff
    }
  }

  public struct State: Equatable, Sendable {
    /// Closed with ×: hidden, but the orb still shows the meeting and a click on it brings the card back.
    public var closed: Set<String>
    /// Joined or declined.
    public var done: Set<String>

    public init(closed: Set<String> = [], done: Set<String> = []) {
      self.closed = closed
      self.done = done
    }
  }

  /// Meetings under way and inside their window, closed or not, soonest first: the orb shows `meeting` while there's
  /// one.
  public static func pending(_ events: [MeetingEvent], now: Date, settings: Settings, state: State) -> [MeetingEvent] {
    events
      .filter { eligible($0, settings: settings, state: state) }
      .filter { $0.start <= now && now < $0.start.addingTimeInterval(cutoff) }
      .sorted { ($0.start, $0.title) < ($1.start, $1.title) }
  }

  /// The meeting whose card shows now: the soonest pending one that isn't closed.
  public static func due(_ events: [MeetingEvent], now: Date, settings: Settings, state: State) -> MeetingEvent? {
    pending(events, now: now, settings: settings, state: state).first { !state.closed.contains($0.id) }
  }

  /// The next moment `due` or `pending` can change: a meeting starting, a cutoff passing.
  public static func nextWake(_ events: [MeetingEvent], now: Date, settings: Settings, state: State) -> Date? {
    events
      .filter { eligible($0, settings: settings, state: state) }
      .flatMap { [$0.start, $0.start.addingTimeInterval(cutoff)] }
      .filter { $0 > now }
      .min()
  }

  /// How long a joined or declined meeting stays done: until it ends, and at least until its cutoff.
  public static func doneUntil(_ event: MeetingEvent) -> Date {
    max(event.end, event.start.addingTimeInterval(cutoff))
  }

  /// The card's first line.
  public static func countdown(start: Date, now: Date) -> String {
    let seconds = start.timeIntervalSince(now)
    if seconds >= 30 { return "Starts in \(Int((seconds / 60).rounded(.up))) min" }
    if seconds > -60 { return "Starting now" }
    return "Started \(Int(-seconds / 60)) min ago"
  }

  private static func eligible(_ event: MeetingEvent, settings: Settings, state: State) -> Bool {
    !event.isAllDay && !event.declined && !settings.calendarsOff.contains(event.calendarID) && !state.done.contains(event.id)
  }
}
