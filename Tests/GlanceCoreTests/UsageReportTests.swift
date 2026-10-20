import Foundation
import Testing
@testable import GlanceCore

private func calendar(_ zone: String = "UTC", firstWeekday: Int = 2) -> Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: zone)!
  calendar.firstWeekday = firstWeekday
  return calendar
}

private func date(_ text: String, _ zone: String = "UTC") -> Date {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.timeZone = TimeZone(identifier: zone)
  formatter.dateFormat = "yyyy-MM-dd HH:mm"
  return formatter.date(from: text)!
}

private func request(_ id: String, at time: Date, model: String = "claude-opus-5-5", project: String = "/Users/me/app",
                     subagent: Bool = false, output: Int = 1_000_000) -> UsageRecord {
  UsageRecord(messageID: id, time: time, model: model, sessionID: "s", project: project, subagent: subagent,
              fast: false, input: 0, output: output, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0)
}

@Test func periodsStartAtTheirDayWeekOrMonth() {
  let utc = calendar()
  let thursday = date("2026-10-08 15:30")
  #expect(UsagePeriod(.day, containing: thursday, calendar: utc).start == date("2026-10-08 00:00"))
  #expect(UsagePeriod(.week, containing: thursday, calendar: utc).start == date("2026-10-05 00:00"))
  #expect(UsagePeriod(.week, containing: thursday, calendar: calendar(firstWeekday: 1)).start == date("2026-10-04 00:00"))
  #expect(UsagePeriod(.month, containing: thursday, calendar: utc).start == date("2026-10-01 00:00"))
  let month = UsagePeriod(.month, containing: thursday, calendar: utc)
  #expect(month.end(utc) == date("2026-11-01 00:00"))
  #expect(month.previous(utc).start == date("2026-09-01 00:00"))
  #expect(month.next(utc).start == date("2026-11-01 00:00"))
  #expect(month.contains(thursday, calendar: utc))
  #expect(!month.contains(date("2026-11-01 00:00"), calendar: utc))
  #expect(month.bucketStarts(utc).count == 31)
  #expect(UsagePeriod(.week, containing: thursday, calendar: utc).bucketStarts(utc).count == 7)
}

@Test func dstDaysHaveTwentyThreeOrTwentyFiveHourlyBuckets() {
  let newYork = calendar("America/New_York")
  #expect(UsagePeriod(.day, containing: date("2026-03-08 12:00", "America/New_York"), calendar: newYork)
    .bucketStarts(newYork).count == 23)
  #expect(UsagePeriod(.day, containing: date("2026-11-01 12:00", "America/New_York"), calendar: newYork)
    .bucketStarts(newYork).count == 25)
}

@Test func aReportAddsUpThePeriodAndComparesItWithTheOneBefore() throws {
  let utc = calendar()
  let week = UsagePeriod(.week, containing: date("2026-10-08 12:00"), calendar: utc)
  let records = [
    request("old", at: date("2026-09-30 09:00")),                                 // last week: $20
    request("a", at: date("2026-10-05 09:00")),                                   // $20
    request("b", at: date("2026-10-08 10:00"), model: "claude-sonnet-5-5"),       // $10
    request("c", at: date("2026-10-08 11:00"), project: "", subagent: true),      // $20, background
    request("d", at: date("2026-10-09 11:00"), model: "claude-mystery-1"),        // unpriced
  ]
  let report = UsageReport.make(period: week, records: records, calendar: utc, trackedSince: date("2026-09-28 00:00"),
                                home: "/Users/me")
  #expect(report.requests == 4)
  #expect(report.totals.output == 4_000_000)
  #expect(abs(report.cost - 50) < 1e-9)
  #expect(report.unpricedTokens == 1_000_000)
  #expect(abs(try #require(report.change) - 1.5) < 1e-9)
  #expect(report.buckets.count == 7)
  #expect(report.buckets[0].tokens.output == 1_000_000)
  #expect(report.buckets[3].tokens.output == 2_000_000)
  #expect(abs(report.buckets[3].cost - 30) < 1e-9)
  #expect(report.models.map(\.name) == ["Opus 5.5", "Sonnet 5.5", "Mystery 1"])
  #expect(abs(report.models[0].share - 0.8) < 1e-9)
  #expect(report.models[2].cost == nil)
  #expect(report.projects.map(\.name) == ["app", UsageReport.backgroundName])
  #expect(report.projects[1].key == "")
  #expect(abs(report.projects[1].subagentShare - 1) < 1e-9)
  #expect(report.trackedSince == date("2026-09-28 00:00"))
}

@Test func anEmptyPeriodHasNoChangeAndEmptyTables() {
  let utc = calendar()
  let day = UsagePeriod(.day, containing: date("2026-10-08 12:00"), calendar: utc)
  let report = UsageReport.make(period: day, records: [], calendar: utc, trackedSince: nil)
  #expect(report.requests == 0)
  #expect(report.change == nil)
  #expect(report.models.isEmpty)
  #expect(report.buckets.count == 24)
}

@Test func withoutAnyPriceSharesFollowTokens() {
  let utc = calendar()
  let day = UsagePeriod(.day, containing: date("2026-10-08 12:00"), calendar: utc)
  let report = UsageReport.make(period: day, records: [
    request("a", at: date("2026-10-08 01:00"), model: "x-1", output: 300),
    request("b", at: date("2026-10-08 02:00"), model: "x-2", output: 100),
  ], calendar: utc, trackedSince: nil)
  #expect(report.models.map(\.share) == [0.75, 0.25])
}

@Test func thereIsNoChangeWhenTrackingBeganAfterThePreviousPeriodStarted() {
  let utc = calendar()
  let week = UsagePeriod(.week, containing: date("2026-10-08 12:00"), calendar: utc)
  let records = [request("old", at: date("2026-10-03 09:00")), request("a", at: date("2026-10-05 09:00"))]
  let partial = UsageReport.make(period: week, records: records, calendar: utc, trackedSince: date("2026-10-03 09:00"))
  #expect(partial.change == nil)
  let whole = UsageReport.make(period: week, records: records, calendar: utc, trackedSince: date("2026-09-28 00:00"))
  #expect(whole.change == 0)
}
