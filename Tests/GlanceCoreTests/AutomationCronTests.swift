import Foundation
import Testing
@testable import GlanceCore

private func calendar(_ zone: String) -> Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: zone)!
  return calendar
}

private let kolkata = calendar("Asia/Kolkata")
private let newYork = calendar("America/New_York")

private func utc(_ text: String) -> Date { try! Date(text, strategy: .iso8601) }

private func cron(_ text: String) -> CronSchedule { try! CronSchedule(parsing: text) }

@Test func cronFieldsParse() {
  let schedule = cron("*/15 9-17 * * mon-fri")
  #expect(schedule.minutes == [0, 15, 30, 45])
  #expect(schedule.hours == Set(9...17))
  #expect(schedule.days == Set(1...31))
  #expect(schedule.weekdays == [1, 2, 3, 4, 5])
  #expect(cron("0 0 * JAN,Jul 7").months == [1, 7])
  #expect(cron("0 0 * * 7").weekdays == [0])
  #expect(cron("5/20 * * * *").minutes == [5, 25, 45])
  #expect(cron("1-10/3 * * * *").minutes == [1, 4, 7, 10])
  #expect(cron("@daily") == cron("@daily"))
  #expect(cron("@daily").hours == [0])
  #expect(cron("@weekly").weekdays == [0])
}

// Review Focus: "*/0" (a step of zero) is a clear problem, never a hang or a crash.
@Test func badCronLinesSayWhy() {
  #expect(throws: CronError.badField(field: "minute", value: "*/0", reason: "the step can't be 0")) {
    try CronSchedule(parsing: "*/0 * * * *")
  }
  #expect(throws: CronError.fieldCount(4)) { try CronSchedule(parsing: "0 9 * *") }
  #expect(throws: CronError.badField(field: "hour", value: "25", reason: "25 is out of range 0–23")) {
    try CronSchedule(parsing: "0 25 * * *")
  }
  #expect(throws: CronError.badField(field: "day", value: "5-1", reason: "the range runs backwards")) {
    try CronSchedule(parsing: "0 0 5-1 * *")
  }
  #expect(throws: CronError.badField(field: "month", value: "foo", reason: "`foo` isn't a number or a name")) {
    try CronSchedule(parsing: "0 0 * foo *")
  }
  #expect(throws: CronError.badField(field: "minute", value: "1,,2", reason: "isn't a value, range or step")) {
    try CronSchedule(parsing: "1,,2 * * * *")
  }
  #expect(CronError.fieldCount(4).message == "needs 5 fields (minute hour day month weekday), found 4")
}

@Test func theNextFireIsStrictlyLater() {
  // Friday 2026-10-09, 10:07 in Kolkata.
  let friday = utc("2026-10-09T04:37:00Z")
  #expect(cron("*/15 * * * *").next(after: friday, calendar: kolkata) == utc("2026-10-09T04:45:00Z"))
  #expect(cron("*/15 * * * *").next(after: utc("2026-10-09T04:45:00Z"), calendar: kolkata)
    == utc("2026-10-09T05:00:00Z"))
  // Weekdays at 9:00 → Monday 2026-10-12 09:00 IST.
  #expect(cron("0 9 * * 1-5").next(after: friday, calendar: kolkata) == utc("2026-10-12T03:30:00Z"))
}

@Test func restrictedDayFieldsMatchEither() {
  // The 13th or any Friday, at midnight IST: after Friday 2026-10-09 10:07 comes Tuesday the 13th, then Friday the 16th.
  let schedule = cron("0 0 13 * 5")
  #expect(schedule.next(after: utc("2026-10-09T04:37:00Z"), calendar: kolkata) == utc("2026-10-12T18:30:00Z"))
  #expect(schedule.next(after: utc("2026-10-12T18:30:00Z"), calendar: kolkata) == utc("2026-10-15T18:30:00Z"))
}

@Test func aLineThatCanNeverFireHasNoNext() {
  #expect(cron("0 0 30 2 *").next(after: utc("2026-10-09T00:00:00Z"), calendar: kolkata) == nil)
  #expect(cron("0 0 30 2 *").previous(atOrBefore: utc("2026-10-09T00:00:00Z"), calendar: kolkata) == nil)
}

@Test func aTimeTheSpringJumpSkipsFiresOnceAfterIt() {
  // New York, Sunday 2026-03-08: 02:00 EST jumps to 03:00 EDT, so 02:30 doesn't exist that night.
  let schedule = cron("30 2 * * *")
  let fire = schedule.next(after: utc("2026-03-08T05:00:00Z"), calendar: newYork)
  #expect(fire == utc("2026-03-08T07:30:00Z"))  // 03:30 EDT
  #expect(schedule.next(after: fire!, calendar: newYork) == utc("2026-03-09T06:30:00Z"))  // 02:30 EDT Monday
}

@Test func aTimeTheAutumnJumpRepeatsFiresOnce() {
  // New York, Sunday 2026-11-01: 02:00 EDT falls back to 01:00 EST, so 01:30 happens twice.
  let schedule = cron("30 1 * * *")
  let first = schedule.next(after: utc("2026-11-01T04:00:00Z"), calendar: newYork)
  #expect(first == utc("2026-11-01T05:30:00Z"))  // 01:30 EDT
  #expect(schedule.next(after: first!, calendar: newYork) == utc("2026-11-02T06:30:00Z"))  // 01:30 EST Monday
  #expect(schedule.previous(atOrBefore: utc("2026-11-01T06:45:00Z"), calendar: newYork) == first)
}

@Test func aScheduleBehindItsDueTimeCatchesUpOnce() {
  let daily = cron("0 9 * * *")
  let yesterdayNine = utc("2026-10-08T03:30:00Z")
  let todayNine = utc("2026-10-09T03:30:00Z")
  let todayEleven = utc("2026-10-09T05:30:00Z")
  #expect(daily.isBehind(lastFire: yesterdayNine, now: todayEleven, calendar: kolkata))
  #expect(!daily.isBehind(lastFire: todayNine, now: todayEleven, calendar: kolkata))
  #expect(!daily.isBehind(lastFire: yesterdayNine, now: utc("2026-10-09T02:30:00Z"), calendar: kolkata))
  #expect(!daily.isBehind(lastFire: nil, now: todayEleven, calendar: kolkata))
  #expect(daily.previous(atOrBefore: todayNine, calendar: kolkata) == todayNine)
}
