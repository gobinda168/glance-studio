import Foundation

/// Why a cron line didn't parse; `message` is what validation shows after "triggers[2].cron: ".
public enum CronError: Error, Equatable, Sendable {
  case fieldCount(Int)
  case badField(field: String, value: String, reason: String)

  public var message: String {
    switch self {
    case .fieldCount(let count):
      "needs 5 fields (minute hour day month weekday), found \(count)"
    case .badField(let field, let value, let reason):
      "\(field) `\(value)`: \(reason)"
    }
  }
}

/// A 5-field cron line (minute hour day-of-month month day-of-week) for schedule triggers: `*`, lists, ranges,
/// steps (`*/15`, `1-30/5`, `5/15`), month and weekday names (JAN, mon), 0 or 7 for Sunday, and @hourly, @daily,
/// @weekly, @monthly, @yearly. When both day fields are restricted, a day matching either runs (as cron does).
///
/// Times are wall-clock times in the calendar's time zone. A time a DST jump skips fires once, right after the jump
/// (02:30 on the spring-forward night runs at 03:30); a time that happens twice fires once, the first time.
public struct CronSchedule: Equatable, Sendable {
  public let text: String
  public let minutes: Set<Int>
  public let hours: Set<Int>
  public let days: Set<Int>
  public let months: Set<Int>
  /// 0 = Sunday … 6 = Saturday.
  public let weekdays: Set<Int>
  let anyDay: Bool
  let anyWeekday: Bool

  static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
  static let weekdayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
  static let macros = ["@hourly": "0 * * * *", "@daily": "0 0 * * *", "@midnight": "0 0 * * *",
                       "@weekly": "0 0 * * 0", "@monthly": "0 0 1 * *", "@yearly": "0 0 1 1 *",
                       "@annually": "0 0 1 1 *"]
  /// How far `next` and `previous` look before deciding a line never fires (Feb 30, or a 31st in only-short months).
  static let searchDays = 366 * 5

  public init(parsing text: String) throws(CronError) {
    self.text = text
    let line = Self.macros[text.trimmingCharacters(in: .whitespaces).lowercased()] ?? text
    let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
    guard fields.count == 5 else { throw .fieldCount(fields.count) }
    minutes = try Self.field(fields[0], name: "minute", range: 0...59, names: [])
    hours = try Self.field(fields[1], name: "hour", range: 0...23, names: [])
    days = try Self.field(fields[2], name: "day", range: 1...31, names: [])
    months = try Self.field(fields[3], name: "month", range: 1...12, names: Self.monthNames)
    let weekdays = try Self.field(fields[4], name: "weekday", range: 0...7, names: Self.weekdayNames)
    self.weekdays = Set(weekdays.map { $0 % 7 })
    anyDay = fields[2].hasPrefix("*")
    anyWeekday = fields[4].hasPrefix("*")
  }

  /// The first fire strictly after `date`; nil when the line can never fire (e.g. "0 0 30 2 *").
  public func next(after date: Date, calendar: Calendar) -> Date? {
    var day = calendar.startOfDay(for: date)
    for _ in 0..<Self.searchDays {
      if let fire = fires(on: day, calendar: calendar).first(where: { $0 > date }) { return fire }
      guard let following = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
      day = calendar.startOfDay(for: following)
    }
    return nil
  }

  /// The latest fire at or before `date`; nil when there is none in the last five years.
  public func previous(atOrBefore date: Date, calendar: Calendar) -> Date? {
    var day = calendar.startOfDay(for: date)
    for _ in 0..<Self.searchDays {
      if let fire = fires(on: day, calendar: calendar).last(where: { $0 <= date }) { return fire }
      guard let before = calendar.date(byAdding: .day, value: -1, to: day) else { return nil }
      day = calendar.startOfDay(for: before)
    }
    return nil
  }

  /// The catch-up rule (spec "Trigger sources"): at launch, a schedule whose last fire is before its most recent due
  /// time fires once. Never fired (nil) is not behind: the engine records the time it armed the schedule instead.
  public func isBehind(lastFire: Date?, now: Date, calendar: Calendar) -> Bool {
    guard let lastFire, let due = previous(atOrBefore: now, calendar: calendar) else { return false }
    return lastFire < due
  }

  /// The day's fire times in order, one per wall-clock match (a skipped time moves past the jump; a repeated time
  /// counts once).
  func fires(on day: Date, calendar: Calendar) -> [Date] {
    let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
    guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day, let weekday = parts.weekday,
          months.contains(month) else { return [] }
    let dayMatches = days.contains(dayOfMonth)
    let weekdayMatches = weekdays.contains(weekday - 1)
    let matches = anyDay || anyWeekday ? dayMatches && weekdayMatches : dayMatches || weekdayMatches
    guard matches else { return [] }
    var fires = Set<Date>()
    for hour in hours {
      for minute in minutes {
        let wall = DateComponents(year: year, month: month, day: dayOfMonth, hour: hour, minute: minute)
        if let fire = calendar.date(from: wall) { fires.insert(fire) }
      }
    }
    return fires.sorted()
  }

  static func field(_ text: String, name: String, range: ClosedRange<Int>,
                    names: [String]) throws(CronError) -> Set<Int> {
    var values = Set<Int>()
    for part in text.split(separator: ",", omittingEmptySubsequences: false).map(String.init) {
      let pieces = part.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
      guard pieces.count <= 2, let base = pieces.first, !base.isEmpty else {
        throw .badField(field: name, value: text, reason: "isn't a value, range or step")
      }
      var step = 1
      if pieces.count == 2 {
        guard let given = Int(pieces[1]) else {
          throw .badField(field: name, value: text, reason: "the step after `/` must be a number")
        }
        guard given > 0 else { throw .badField(field: name, value: text, reason: "the step can't be 0") }
        step = given
      }
      let low: Int, high: Int
      if base == "*" {
        (low, high) = (range.lowerBound, range.upperBound)
      } else if let dash = base.firstIndex(of: "-") {
        low = try value(String(base[..<dash]), field: name, text: text, range: range, names: names)
        high = try value(String(base[base.index(after: dash)...]), field: name, text: text, range: range, names: names)
        guard low <= high else {
          throw .badField(field: name, value: text, reason: "the range runs backwards")
        }
      } else {
        low = try value(base, field: name, text: text, range: range, names: names)
        high = pieces.count == 2 ? range.upperBound : low
      }
      values.formUnion(stride(from: low, through: high, by: step))
    }
    return values
  }

  static func value(_ token: String, field: String, text: String, range: ClosedRange<Int>,
                    names: [String]) throws(CronError) -> Int {
    if let number = Int(token) {
      guard range.contains(number) else {
        throw .badField(field: field, value: text,
                        reason: "\(number) is out of range \(range.lowerBound)–\(range.upperBound)")
      }
      return number
    }
    if let index = names.firstIndex(of: token.lowercased()) {
      return index + range.lowerBound
    }
    throw .badField(field: field, value: text, reason: "`\(token)` isn't a number or a name")
  }
}
