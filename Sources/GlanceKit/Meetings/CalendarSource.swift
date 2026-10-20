import AppKit
import EventKit
import GlanceCore

/// The Mac's calendars through EventKit (spec 2026-10-08-meeting-nudges-design.md, "CalendarSource"): whatever accounts
/// Calendar has (the user's Google Workspace), no sign-in of Glance's own.
@MainActor
public final class CalendarSource {
  public enum Access: Sendable { case allowed, denied, notAsked }

  public struct Calendar: Identifiable {
    public let id: String
    public let title: String
    public let account: String
    public let color: CGColor
  }

  /// The calendar database changed (an event moved, a reply sent, an account synced).
  var onChange: (() -> Void)?
  private let store = EKEventStore()

  init() {
    NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.onChange?() }
    }
  }

  public var access: Access {
    switch EKEventStore.authorizationStatus(for: .event) {
    case .fullAccess: .allowed
    case .notDetermined: .notAsked
    default: .denied
    }
  }

  func requestAccess(_ done: @escaping @MainActor (Bool) -> Void) {
    // @Sendable: EventKit answers on its own queue, where a main-actor closure traps (Swift 6).
    store.requestFullAccessToEvents { @Sendable granted, _ in
      Task { @MainActor in done(granted) }
    }
  }

  public func calendars() -> [Calendar] {
    guard access == .allowed else { return [] }
    return store.calendars(for: .event)
      .map { Calendar(id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? "Other",
                      color: $0.cgColor ?? NSColor.systemGray.cgColor) }
      .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
  }

  func color(of calendarID: String) -> CGColor? {
    store.calendar(withIdentifier: calendarID)?.cgColor
  }

  public func events(from start: Date, to end: Date) -> [MeetingEvent] {
    guard access == .allowed else { return [] }
    let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
    return store.events(matching: predicate).map { event in
      let me = event.attendees?.first { $0.isCurrentUser }
      let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return MeetingEvent(
        id: MeetingEvent.occurrenceID(eventID: event.eventIdentifier ?? event.calendarItemIdentifier, start: event.startDate),
        calendarID: event.calendar.calendarIdentifier, calendarTitle: event.calendar.title,
        title: title.isEmpty ? "Untitled meeting" : title, start: event.startDate, end: event.endDate,
        isAllDay: event.isAllDay, declined: event.status == .canceled || me?.participantStatus == .declined,
        link: MeetingLink.find(url: event.url?.absoluteString, location: [event.location, event.structuredLocation?.title].compactMap { $0 }.joined(separator: " "),
                              notes: event.notes),
        iCalUID: event.calendarItemExternalIdentifier)
    }
  }
}
