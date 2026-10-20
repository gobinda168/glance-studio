import Foundation

/// A calendar day in Journal (spec 2026-10-09-journal-design.md, "Storage"): the local date "YYYY-MM-DD" in the time
/// zone the Mac was in when the day was collected. An event belongs to the day it started on.
public struct JournalDay: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
  public let key: String

  public init?(key: String) {
    let parts = key.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
          Int(parts[0]) != nil, let month = Int(parts[1]), let day = Int(parts[2]),
          (1...12).contains(month), (1...31).contains(day) else { return nil }
    self.key = key
  }

  /// The day `date` falls on in `calendar`'s time zone.
  public init(_ date: Date, calendar: Calendar) {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    key = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 1, parts.day ?? 1)
  }

  /// A Gregorian calendar in `timeZone`: Journal's day arithmetic never depends on the user's calendar settings.
  public static func calendar(timeZone: TimeZone = .current) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
  }

  private var parts: DateComponents {
    let numbers = key.split(separator: "-").compactMap { Int($0) }
    return DateComponents(year: numbers[0], month: numbers[1], day: numbers[2], hour: 12)
  }

  /// Noon, which every day has whatever the clocks do.
  private func noon(in calendar: Calendar) -> Date {
    calendar.date(from: parts) ?? Date(timeIntervalSince1970: 0)
  }

  public func start(in calendar: Calendar) -> Date {
    calendar.startOfDay(for: noon(in: calendar))
  }

  /// From this day's first moment to the next day's: 23 or 25 hours when the clocks change.
  public func interval(in calendar: Calendar) -> DateInterval {
    DateInterval(start: start(in: calendar), end: adding(days: 1, calendar: calendar).start(in: calendar))
  }

  public func adding(days: Int, calendar: Calendar) -> JournalDay {
    JournalDay(calendar.date(byAdding: .day, value: days, to: noon(in: calendar)) ?? noon(in: calendar),
               calendar: calendar)
  }

  /// Every day from `from` through `through`, oldest first; empty when `through` comes first.
  public static func range(from: JournalDay, through: JournalDay, calendar: Calendar) -> [JournalDay] {
    var days: [JournalDay] = []
    var day = from
    while day <= through {
      days.append(day)
      day = day.adding(days: 1, calendar: calendar)
    }
    return days
  }

  public static func < (lhs: JournalDay, rhs: JournalDay) -> Bool { lhs.key < rhs.key }

  public var description: String { key }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let text = try container.decode(String.self)
    guard let day = JournalDay(key: text) else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a day: \(text)")
    }
    self = day
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(key)
  }
}
