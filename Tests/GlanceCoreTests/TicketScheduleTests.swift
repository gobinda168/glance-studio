import Foundation
import Testing
@testable import GlanceCore

private var calendar: Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
  return calendar
}

private func at(_ hour: Int, _ minute: Int = 0, day: Int = 9) -> Date {
  calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
}

@Test func dayKeysAreLocalDates() {
  #expect(TicketSchedule.dayKey(at(0, 30), calendar: calendar) == "2026-10-09")
}

@Test func theMorningComesOnceAtTheFirstActivity() {
  let prefs = TicketPrefs()
  #expect(!TicketSchedule.morningDue(now: at(8, 59), prefs: prefs, lastDay: nil, idle: 1, calendar: calendar))
  #expect(TicketSchedule.morningDue(now: at(11), prefs: prefs, lastDay: "2026-10-08", idle: 5, calendar: calendar))
  #expect(!TicketSchedule.morningDue(now: at(11), prefs: prefs, lastDay: nil, idle: 600, calendar: calendar))
  #expect(!TicketSchedule.morningDue(now: at(11), prefs: prefs, lastDay: "2026-10-09", idle: 5, calendar: calendar))
}

@Test func aFixedMorningIgnoresActivity() {
  var prefs = TicketPrefs()
  prefs.morningFixed = true
  prefs.morningMinutes = 9 * 60 + 30
  #expect(TicketSchedule.morningDue(now: at(9, 31), prefs: prefs, lastDay: nil, idle: 9_999, calendar: calendar))
  #expect(!TicketSchedule.morningDue(now: at(9, 29), prefs: prefs, lastDay: nil, idle: 0, calendar: calendar))
}

@Test func theCheckInWaitsForItsTimeAndActivity() {
  var prefs = TicketPrefs()
  #expect(TicketSchedule.checkInDue(now: at(18, 30), prefs: prefs, lastDay: nil, idle: 10, calendar: calendar))
  #expect(!TicketSchedule.checkInDue(now: at(17, 59), prefs: prefs, lastDay: nil, idle: 10, calendar: calendar))
  #expect(!TicketSchedule.checkInDue(now: at(18, 30), prefs: prefs, lastDay: "2026-10-09", idle: 10, calendar: calendar))
  #expect(!TicketSchedule.checkInDue(now: at(18, 30), prefs: prefs, lastDay: nil, idle: 600, calendar: calendar))
  prefs.checkIn = false
  #expect(!TicketSchedule.checkInDue(now: at(18, 30), prefs: prefs, lastDay: nil, idle: 10, calendar: calendar))
}
