import Foundation
import GlanceCore

/// Meeting notes' preferences (Settings → Meetings → Meeting notes, spec 2026-10-09-meeting-notes-design.md).
extension Prefs {
  /// Keep a meeting's audio after its notes are done. Off: the audio is deleted then.
  public static var meetingKeepRecordings: Bool {
    get { defaults.bool(forKey: "meetingKeepRecordings") }
    set { defaults.set(newValue, forKey: "meetingKeepRecordings") }
  }

  /// The meeting nudge offers Join & Record.
  public static var meetingOfferRecording: Bool {
    get { defaults.object(forKey: "meetingOfferRecording") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "meetingOfferRecording") }
  }

  /// A pill offers Record when a call app starts using the mic (Zoom, Teams, Slack, a browser…).
  public static var meetingOfferCalls: Bool {
    get { defaults.object(forKey: "meetingOfferCalls") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "meetingOfferCalls") }
  }
}
