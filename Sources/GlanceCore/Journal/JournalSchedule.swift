import Foundation

/// When Journal does things (spec 2026-10-09-journal-design.md, "When collection runs" and "Wrap-up time").
public enum JournalSchedule {
  /// 19:00, in minutes after midnight.
  public static let defaultWrapUp = 19 * 60
  public static let catchUpDays = 14
  public static let catchUpDrafts = 7

  /// The next moment after `now` at `minutes` past midnight, local. On the night the clocks skip that time, the first
  /// moment after the gap.
  public static func nextWrapUp(after now: Date, minutes: Int, calendar: Calendar) -> Date {
    let parts = DateComponents(hour: minutes / 60, minute: minutes % 60, second: 0)
    return calendar.nextDate(after: now, matching: parts, matchingPolicy: .nextTime) ?? now.addingTimeInterval(86_400)
  }

  /// The past days to collect at launch, oldest first: those after the last collected, through yesterday, at most
  /// the latest `catchUpDays`; with nothing collected yet, the `catchUpDays` days before today.
  public static func catchUp(today: JournalDay, lastCollected: JournalDay?, calendar: Calendar) -> [JournalDay] {
    let earliest = today.adding(days: -catchUpDays, calendar: calendar)
    let from = max(earliest, lastCollected.map { $0.adding(days: 1, calendar: calendar) } ?? earliest)
    return JournalDay.range(from: from, through: today.adding(days: -1, calendar: calendar), calendar: calendar)
  }

  /// The past days with events and no recap yet, oldest first, at most `catchUpDrafts`.
  public static func daysToDraft(_ summaries: [JournalDaySummary], today: JournalDay) -> [JournalDay] {
    Array(summaries.filter { $0.day < today && $0.status == .open && $0.eventCount > 0 }.map(\.day).sorted()
      .prefix(catchUpDrafts))
  }

  /// The wrap-up drafts a day that has events and isn't reviewed yet.
  public static func shouldWrapUp(_ summary: JournalDaySummary?) -> Bool {
    guard let summary else { return false }
    return summary.eventCount > 0 && summary.status != .reviewed
  }
}
