import Foundation
import Testing
@testable import GlanceCore

private let utc = JournalDay.calendar(timeZone: TimeZone(identifier: "UTC")!)
private func at(_ text: String) -> Date { JournalTime.parse(text)! }

@Test func aDayKeyIsValidatedAndOrdered() {
  #expect(JournalDay(key: "2026-10-09")?.key == "2026-10-09")
  #expect(JournalDay(key: "2026-13-01") == nil)
  #expect(JournalDay(key: "2026-10-9") == nil)
  #expect(JournalDay(key: "yesterday") == nil)
  #expect(JournalDay(key: "2026-10-09")! < JournalDay(key: "2026-10-10")!)
}

@Test func aDayIsTheLocalDateOfAMoment() {
  let kolkata = JournalDay.calendar(timeZone: TimeZone(identifier: "Asia/Kolkata")!)
  // 20:00 UTC on the 9th is 01:30 on the 10th in Kolkata.
  #expect(JournalDay(at("2026-10-09T20:00:00Z"), calendar: utc).key == "2026-10-09")
  #expect(JournalDay(at("2026-10-09T20:00:00Z"), calendar: kolkata).key == "2026-10-10")
  let interval = JournalDay(key: "2026-10-10")!.interval(in: kolkata)
  #expect(interval.start == at("2026-10-09T18:30:00Z"))
  #expect(interval.duration == 24 * 3600)
}

@Test func aDayIsTwentyThreeHoursWhenClocksGoForward() {
  let newYork = JournalDay.calendar(timeZone: TimeZone(identifier: "America/New_York")!)
  #expect(JournalDay(key: "2026-03-08")!.interval(in: newYork).duration == 23 * 3600)
  #expect(JournalDay(key: "2026-03-08")!.adding(days: 1, calendar: newYork).key == "2026-03-09")
}

@Test func daysAddAndRange() {
  let day = JournalDay(key: "2026-10-30")!
  #expect(day.adding(days: 3, calendar: utc).key == "2026-11-02")
  #expect(day.adding(days: -30, calendar: utc).key == "2026-09-30")
  #expect(JournalDay.range(from: day, through: day.adding(days: 2, calendar: utc), calendar: utc).map(\.key)
    == ["2026-10-30", "2026-10-31", "2026-11-01"])
  #expect(JournalDay.range(from: day, through: day.adding(days: -1, calendar: utc), calendar: utc).isEmpty)
}

@Test func aDayEncodesAsItsKey() throws {
  let data = try JSONEncoder().encode([JournalDay(key: "2026-10-09")!])
  #expect(String(decoding: data, as: UTF8.self) == #"["2026-10-09"]"#)
  #expect(try JSONDecoder().decode([JournalDay].self, from: data).first?.key == "2026-10-09")
  #expect(throws: DecodingError.self) { try JSONDecoder().decode([JournalDay].self, from: Data(#"["soon"]"#.utf8)) }
}

@Test func joinedPointsBecomeSpansBrokenByLongGaps() {
  let points = ["10:00", "10:05", "10:10", "11:00", "11:05"].map { at("2026-10-09T\($0):00Z") }
  let spans = JournalSpans.join(points, gap: 15 * 60)
  #expect(spans == [JournalSpan(start: points[0], end: points[2]), JournalSpan(start: points[3], end: points[4])])
  #expect(JournalSpans.minutes(spans) == 15)
}

@Test func aLonePointCountsAMinute() {
  let spans = JournalSpans.join([at("2026-10-09T10:00:00Z")], gap: 900)
  #expect(JournalSpans.minutes(spans) == 1)
  #expect(JournalSpans.join([], gap: 900).isEmpty)
}

@Test func spansUnionSubtractAndClip() {
  let a = JournalSpan(start: at("2026-10-09T10:00:00Z"), end: at("2026-10-09T11:00:00Z"))
  let b = JournalSpan(start: at("2026-10-09T10:30:00Z"), end: at("2026-10-09T11:30:00Z"))
  let meeting = JournalSpan(start: at("2026-10-09T10:45:00Z"), end: at("2026-10-09T11:15:00Z"))
  #expect(JournalSpans.union([b, a]) == [JournalSpan(start: a.start, end: b.end)])
  #expect(JournalSpans.minutes([a, b]) == 90)
  #expect(JournalSpans.subtract([a, b], [meeting]) == [
    JournalSpan(start: a.start, end: meeting.start), JournalSpan(start: meeting.end, end: b.end),
  ])
  let morning = DateInterval(start: at("2026-10-09T10:15:00Z"), end: at("2026-10-09T10:40:00Z"))
  #expect(JournalSpans.clip([a], to: morning) == [JournalSpan(start: morning.start, end: morning.end)])
  #expect(JournalSpans.clip([meeting], to: morning).isEmpty)
}

@Test func cleanRedactsCollapsesAndCuts() {
  let token = "ghp_" + String(repeating: "a", count: 36)
  let cleaned = JournalText.clean("deploy  with\n\(token) now", limit: 200)
  #expect(cleaned.hasPrefix("deploy with "))
  #expect(!cleaned.contains(token))
  #expect(cleaned.contains("‹redacted›"))
  #expect(JournalText.clean("abcdefghij", limit: 5) == "abcd…")
  #expect(JournalText.clean("  short  ", limit: 5) == "short")
  #expect(JournalText.trim("one\n\ntwo  ", limit: 100) == "one\n\ntwo")
  #expect(JournalText.trim("abcdefghij", limit: 5) == "abcd…")
}

@Test func anEventIsKnownBySourceAndExternalID() {
  let event = JournalEvent(source: .git, externalID: "abc", day: JournalDay(key: "2026-10-09")!,
                           start: at("2026-10-09T10:00:00Z"), title: "fix")
  #expect(event.id == "git:abc")
}

@Test func timesParseWithOrWithoutFractions() {
  #expect(JournalTime.parse("2026-10-09T08:56:30.997Z") != nil)
  #expect(JournalTime.parse("2026-10-09T08:56:30Z") != nil)
  #expect(JournalTime.parse("2026-10-09T14:26:30+05:30") == JournalTime.parse("2026-10-09T08:56:30Z"))
  #expect(JournalTime.parse("not a time") == nil)
}
