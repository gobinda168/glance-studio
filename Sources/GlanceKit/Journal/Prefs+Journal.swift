import Foundation
import GlanceCore

/// Journal's preferences (Settings → Journal, spec 2026-10-09-journal-design.md).
extension Prefs {
  /// Journaling on: collection, the wrap-up and catch-up run. Off until the setup page's Start journaling.
  public static var journalEnabled: Bool {
    get { defaults.bool(forKey: "journalEnabled") }
    set { defaults.set(newValue, forKey: "journalEnabled") }
  }

  /// The sources switched off; a new source starts on.
  public static var journalSourcesOff: Set<JournalSource> {
    get { Set((defaults.stringArray(forKey: "journalSourcesOff") ?? []).compactMap(JournalSource.init(rawValue:))) }
    set { defaults.set(newValue.map(\.rawValue).sorted(), forKey: "journalSourcesOff") }
  }

  public static var journalWrapUp: Bool {
    get { defaults.object(forKey: "journalWrapUp") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "journalWrapUp") }
  }

  /// The wrap-up time, in minutes after local midnight.
  public static var journalWrapUpMinutes: Int {
    get { defaults.object(forKey: "journalWrapUpMinutes") as? Int ?? JournalSchedule.defaultWrapUp }
    set { defaults.set(newValue, forKey: "journalWrapUpMinutes") }
  }

  /// The day the wrap-up last ran ("YYYY-MM-DD"), so a Mac asleep at the time still wraps up once when it wakes.
  public static var journalLastWrapUpDay: String? {
    get { defaults.string(forKey: "journalLastWrapUpDay") }
    set { defaults.set(newValue, forKey: "journalLastWrapUpDay") }
  }
}
