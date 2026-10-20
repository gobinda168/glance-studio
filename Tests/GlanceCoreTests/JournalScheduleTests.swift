import Foundation
import Testing
@testable import GlanceCore

private let utc = JournalDay.calendar(timeZone: TimeZone(identifier: "UTC")!)
private func d(_ key: String) -> JournalDay { JournalDay(key: key)! }
private func t(_ text: String) -> Date { JournalTime.parse(text)! }

@Test func wrapUpLandsOnTheChosenLocalTimeAcrossDST() {
  let kolkata = JournalDay.calendar(timeZone: TimeZone(identifier: "Asia/Kolkata")!)
  #expect(JournalSchedule.nextWrapUp(after: t("2026-10-09T12:30:00Z"), minutes: 1140, calendar: kolkata)
    == t("2026-10-09T13:30:00Z"))
  #expect(JournalSchedule.nextWrapUp(after: t("2026-10-09T14:00:00Z"), minutes: 1140, calendar: kolkata)
    == t("2026-10-10T13:30:00Z"))
  let newYork = JournalDay.calendar(timeZone: TimeZone(identifier: "America/New_York")!)
  // Clocks go back on 1 November 2026: 19:00 that evening is UTC−5.
  #expect(JournalSchedule.nextWrapUp(after: t("2026-11-01T16:00:00Z"), minutes: 1140, calendar: newYork)
    == t("2026-11-02T00:00:00Z"))
  // Clocks go forward on 8 March 2026: 02:30 doesn't exist that night, so it comes at 03:00.
  #expect(JournalSchedule.nextWrapUp(after: t("2026-03-08T06:00:00Z"), minutes: 150, calendar: newYork)
    == t("2026-03-08T07:00:00Z"))
}

@Test func catchUpCollectsTheMissedDaysUpToFourteen() {
  let today = d("2026-10-09")
  let fresh = JournalSchedule.catchUp(today: today, lastCollected: nil, calendar: utc)
  #expect(fresh.count == 14 && fresh.first?.key == "2026-09-25" && fresh.last?.key == "2026-10-08")
  #expect(JournalSchedule.catchUp(today: today, lastCollected: d("2026-10-06"), calendar: utc).map(\.key)
    == ["2026-10-07", "2026-10-08"])
  #expect(JournalSchedule.catchUp(today: today, lastCollected: d("2026-10-08"), calendar: utc).isEmpty)
  #expect(JournalSchedule.catchUp(today: today, lastCollected: d("2026-08-01"), calendar: utc).count == 14)
}

@Test func catchUpDraftsAtMostSevenOpenPastDaysOldestFirst() {
  func summary(_ key: String, _ status: JournalDayRecord.Status, events: Int = 3) -> JournalDaySummary {
    JournalDaySummary(day: d(key), status: status, headline: "", eventCount: events, entryCount: 0, newSinceRecap: 0)
  }
  let summaries = (1...8).map { summary(String(format: "2026-10-%02d", $0), .open) }
    + [summary("2026-10-09", .open), summary("2026-09-30", .drafted), summary("2026-09-29", .failed),
       summary("2026-09-28", .open, events: 0)]
  #expect(JournalSchedule.daysToDraft(summaries, today: d("2026-10-09")).map(\.key)
    == (1...7).map { String(format: "2026-10-%02d", $0) })
}

@Test func theWrapUpRunsOnADayWithEventsThatIsntReviewed() {
  func summary(_ status: JournalDayRecord.Status, events: Int) -> JournalDaySummary {
    JournalDaySummary(day: d("2026-10-09"), status: status, headline: "", eventCount: events, entryCount: 0,
                      newSinceRecap: 0)
  }
  #expect(JournalSchedule.shouldWrapUp(summary(.open, events: 2)))
  #expect(JournalSchedule.shouldWrapUp(summary(.drafted, events: 2)))
  #expect(!JournalSchedule.shouldWrapUp(summary(.reviewed, events: 2)))
  #expect(!JournalSchedule.shouldWrapUp(summary(.open, events: 0)))
  #expect(!JournalSchedule.shouldWrapUp(nil))
}

@Test func theExportRoundTripsAsJSON() throws {
  let day = d("2026-10-09")
  let now = t("2026-10-09T18:00:00Z")
  let file = JournalExport.File(
    schema: 1, exportedAt: now, days: [JournalDayRecord(day: day, status: .reviewed, headline: "H", recap: "R")],
    events: [JournalEvent(source: .note, externalID: "n", day: day, start: now, title: "note")],
    entries: [JournalEntry(id: "e", day: day, title: "T", skills: ["ai"], createdAt: now)])
  let data = try JournalExport.json(days: file.days, events: file.events, entries: file.entries, exportedAt: now)
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  #expect(try decoder.decode(JournalExport.File.self, from: data) == file)
  #expect(String(decoding: data, as: UTF8.self).contains("\"day\" : \"2026-10-09\""))
}

@Test func theMarkdownHasAFilePerMonthWithEveryStory() {
  let now = t("2026-10-09T18:00:00Z")
  let days = [
    JournalDayRecord(day: d("2026-10-09"), status: .reviewed, headline: "Faster startup", recap: "I fixed it."),
    JournalDayRecord(day: d("2026-09-30"), status: .drafted, headline: "Landing page", recap: "Built it."),
    JournalDayRecord(day: d("2026-09-29")),
  ]
  let entries = [JournalEntry(day: d("2026-10-09"), title: "Gunicorn startup", summary: "Health checks no longer count.",
                              project: "/code/api", kind: .fixed, impact: "292 s → 40 s", challenge: "Hard to see",
                              approach: "Traced it", outcome: "Faster", lesson: "Measure first",
                              skills: ["performance", "debugging"], minutes: 95, highlight: true, createdAt: now)]
  let files = JournalExport.markdown(days: days, entries: entries, calendar: utc,
                                     name: { $0.split(separator: "/").last.map(String.init) ?? $0 })
  #expect(files.keys.sorted() == ["2026-09.md", "2026-10.md"])
  let october = files["2026-10.md"] ?? ""
  #expect(october.hasPrefix("# October 2026\n"))
  #expect(october.contains("## Friday 9 October 2026 · Faster startup"))
  #expect(october.contains("### ★ Gunicorn startup"))
  #expect(october.contains("Fixed · api · 1 h 35 min"))
  #expect(october.contains("- **Impact:** 292 s → 40 s"))
  #expect(october.contains("- **Lesson:** Measure first"))
  #expect(october.contains("- **Skills:** performance, debugging"))
  #expect(!(files["2026-09.md"] ?? "").contains("29 September"))
  #expect([30, 60, 95, 0].map { JournalExport.duration(minutes: $0) } == ["30 min", "1 h", "1 h 35 min", "0 min"])
}
