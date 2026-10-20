import AppKit
import Combine
import GlanceCore

/// Settings → Meetings' state (spec 2026-10-08-meeting-nudges-design.md, "Settings → Meetings"): the switches, the
/// calendars switched off, and calendar access. Every change re-decides the nudge.
@MainActor
public final class MeetingSettingsModel: ObservableObject {
  public static let shared = MeetingSettingsModel()

  @Published public private(set) var nudges = Prefs.meetingNudges
  @Published public private(set) var speak = Prefs.meetingSpeak
  @Published public private(set) var sound = Prefs.meetingSound
  @Published public private(set) var joinInBrowser = Prefs.meetingJoinInBrowser
  @Published public private(set) var calendarsOff = Set(Prefs.meetingCalendarsOff)
  @Published public private(set) var access = CalendarSource.Access.notAsked
  @Published public private(set) var calendars: [CalendarSource.Calendar] = []

  private var nudger: MeetingNudger { .shared }

  private init() { reload() }

  /// Reads access and the calendar list again (the page appears, access changed, an account synced).
  public func reload() {
    access = nudger.calendar.access
    calendars = nudger.calendar.calendars()
  }

  public func setNudges(_ on: Bool) {
    nudges = on
    Prefs.meetingNudges = on
    if on && access == .notAsked { requestAccess() }
    nudger.refresh()
  }

  public func setSpeak(_ on: Bool) {
    speak = on
    Prefs.meetingSpeak = on
  }

  public func setSound(_ on: Bool) {
    sound = on
    Prefs.meetingSound = on
  }

  public func setJoinInBrowser(_ on: Bool) {
    joinInBrowser = on
    Prefs.meetingJoinInBrowser = on
  }

  public func setCalendar(_ id: String, on: Bool) {
    if on { calendarsOff.remove(id) } else { calendarsOff.insert(id) }
    Prefs.meetingCalendarsOff = calendarsOff.sorted()
    nudger.refresh()
  }

  /// Settings' "Show a test nudge": the made-up meeting, now.
  public func showTestNudge() {
    nudger.showTest(after: 0.2)
  }

  public func requestAccess() {
    Prefs.meetingAccessAsked = true
    nudger.calendar.requestAccess { [weak self] _ in
      self?.reload()
      MeetingNudger.shared.refresh()
    }
  }

  public func openPrivacySettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
      NSWorkspace.shared.open(url)
    }
  }
}
