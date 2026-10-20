import Foundation

/// When the morning card and the end-of-day check-in run (spec "Morning card and check-in"): once a day each, at the
/// user's first activity after their time (the morning can be a fixed time instead).
public enum TicketSchedule {
  /// Input within the last minute counts as the user being here.
  public static let activeWithin: TimeInterval = 60

  public static func dayKey(_ date: Date, calendar: Calendar) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  public static func morningDue(now: Date, prefs: TicketPrefs, lastDay: String?, idle: TimeInterval,
                                calendar: Calendar) -> Bool {
    guard dayKey(now, calendar: calendar) != lastDay,
          let start = time(prefs.morningMinutes, on: now, calendar: calendar), now >= start else { return false }
    return prefs.morningFixed || idle < activeWithin
  }

  public static func checkInDue(now: Date, prefs: TicketPrefs, lastDay: String?, idle: TimeInterval,
                                calendar: Calendar) -> Bool {
    guard prefs.checkIn, dayKey(now, calendar: calendar) != lastDay,
          let start = time(prefs.checkInMinutes, on: now, calendar: calendar), now >= start else { return false }
    return idle < activeWithin
  }

  static func time(_ minutes: Int, on date: Date, calendar: Calendar) -> Date? {
    calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: date)
  }
}
