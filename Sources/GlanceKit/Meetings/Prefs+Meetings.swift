import Foundation
import GlanceCore

/// Meeting nudges' preferences (Settings → Meetings, spec 2026-10-08-meeting-nudges-design.md).
extension Prefs {
  public static var meetingNudges: Bool {
    get { defaults.object(forKey: "meetingNudges") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "meetingNudges") }
  }

  /// Glance says the meeting out loud when its card first appears (in place of the chime).
  public static var meetingSpeak: Bool {
    get { defaults.object(forKey: "meetingSpeak") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "meetingSpeak") }
  }

  public static var meetingSound: Bool {
    get { defaults.object(forKey: "meetingSound") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "meetingSound") }
  }

  /// Join opens the call in a Studio Browser tab (which can float, PiP) instead of the call's app or the browser.
  public static var meetingJoinInBrowser: Bool {
    get { defaults.object(forKey: "meetingJoinInBrowser") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "meetingJoinInBrowser") }
  }

  /// Calendars switched off; new calendars start on.
  public static var meetingCalendarsOff: [String] {
    get { defaults.stringArray(forKey: "meetingCalendarsOff") ?? [] }
    set { defaults.set(newValue, forKey: "meetingCalendarsOff") }
  }

  /// Calendar access was asked for once at launch; after that only Settings asks.
  static var meetingAccessAsked: Bool {
    get { defaults.bool(forKey: "meetingAccessAsked") }
    set { defaults.set(newValue, forKey: "meetingAccessAsked") }
  }

  /// Meetings joined or declined, by occurrence id, until `MeetingAgenda.doneUntil`.
  static var meetingsDone: [String: Date] {
    get {
      (defaults.dictionary(forKey: "meetingsDone") as? [String: Double] ?? [:]).mapValues { Date(timeIntervalSince1970: $0) }
    }
    set { defaults.set(newValue.mapValues(\.timeIntervalSince1970), forKey: "meetingsDone") }
  }
}
