import Foundation
import Testing
@testable import GlanceCore

private let utc = JournalDay.calendar(timeZone: TimeZone(identifier: "UTC")!)
private func d(_ key: String) -> JournalDay { JournalDay(key: key)! }
private let friday = d("2026-10-09")
private func at(_ time: String, _ date: String = "2026-10-09") -> Date { JournalTime.parse("\(date)T\(time):00Z")! }
private func span(_ from: String, _ to: String) -> JournalSpan { JournalSpan(start: at(from), end: at(to)) }

private func activity(_ day: JournalDay, _ minutes: Int, hours: [Int: Int] = [:],
                      projects: [String: Int] = [:]) -> JournalDayActivity {
  var hourMinutes = Array(repeating: 0, count: 24)
  for (hour, value) in hours { hourMinutes[hour] = value }
  return JournalDayActivity(day: day, activeMinutes: minutes, focusMinutes: minutes, meetingMinutes: 0,
                            projectMinutes: projects, hourMinutes: hourMinutes)
}

@Test func aDaysActivityJoinsItsSourcesAndTakesMeetingsOut() {
  let events = [
    JournalEvent(source: .claude, externalID: "s:1", day: friday, start: at("10:00"), end: at("11:00"), project: "/a",
                 title: "s", detail: JournalDetail(spans: [span("10:00", "11:00")])),
    JournalEvent(source: .git, externalID: "c", day: friday, start: at("14:00"), project: "/b", title: "c"),
    JournalEvent(source: .meeting, externalID: "m", day: friday, start: at("10:45"), end: at("11:15"), title: "m"),
    JournalEvent(source: .pr, externalID: "p", day: friday, start: at("16:00"), project: "/a", title: "p"),
  ]
  let result = JournalAnalytics.activity(day: friday, events: events, terminal: ["/a": [span("10:30", "11:30")]],
                                         fallback: [:], calendar: utc)
  #expect(result.activeMinutes == 95)
  #expect(result.meetingMinutes == 30)
  #expect(result.focusMinutes == 65)
  #expect(result.projectMinutes == ["/a": 60, "/b": 5])
  #expect(result.hourMinutes[10] == 60 && result.hourMinutes[11] == 30 && result.hourMinutes[13] == 5)
  #expect(result.hourMinutes.reduce(0, +) == 95)
}

@Test func aDayWithNoTimesUsesClaudesEstimate() {
  let result = JournalAnalytics.activity(day: friday, events: [], terminal: [:], fallback: ["/a": 120, "/b": 0],
                                         calendar: utc)
  #expect(result.activeMinutes == 120 && result.focusMinutes == 120)
  #expect(result.projectMinutes == ["/a": 120])
}

@Test func aDayQualifiesWithFifteenMinutesOrAnEntry() {
  #expect(JournalAnalytics.qualifies(activity(friday, 15), entries: 0))
  #expect(!JournalAnalytics.qualifies(activity(friday, 14), entries: 0))
  #expect(JournalAnalytics.qualifies(nil, entries: 1))
}

@Test func streaksCountBackFromTodayOrYesterday() {
  let days: Set = [d("2026-10-01"), d("2026-10-02"), d("2026-10-03"), d("2026-10-04"), d("2026-10-07"), d("2026-10-08"),
                   d("2026-10-09")]
  #expect(JournalAnalytics.streaks(days, today: d("2026-10-09"), calendar: utc) == (current: 3, longest: 4))
  #expect(JournalAnalytics.streaks(days, today: d("2026-10-10"), calendar: utc).current == 3)
  #expect(JournalAnalytics.streaks(days, today: d("2026-10-11"), calendar: utc).current == 0)
  #expect(JournalAnalytics.streaks([], today: friday, calendar: utc) == (current: 0, longest: 0))
}

@Test func levelsStepAtOneThreeAndFiveHours() {
  #expect([0, 1, 59, 60, 179, 180, 299, 300, 900].map { JournalAnalytics.level(minutes: $0) } == [0, 1, 1, 2, 2, 3, 3, 4, 4])
}

@Test func theGridEndsThisWeekWithFutureDaysBlank() {
  let grid = JournalAnalytics.grid(today: friday, weeks: 53,
                                   minutes: [friday: 200, d("2026-10-08"): 30, d("2026-10-07"): 400], calendar: utc)
  #expect(grid.count == 53)
  #expect(grid.allSatisfy { $0.count == 7 })
  #expect(grid.last?.first?.day.key == "2026-10-04")
  #expect(grid.first?.first?.day.key == "2025-10-05")
  #expect(grid.last?.filter(\.isFuture).map(\.day.key) == ["2026-10-10"])
  #expect(grid.last?.map(\.level) == [0, 0, 0, 4, 1, 3, 0])
}

@Test func theBusiestWeekdayIsTheBestAverageAndTheBusiestHourTheMostMinutes() {
  let busiest = JournalAnalytics.busiest([
    activity(friday, 120, hours: [10: 120]), activity(d("2026-10-02"), 0),
    activity(d("2026-10-08"), 50, hours: [15: 50]),
  ], calendar: utc)
  #expect(busiest.weekday == 6)
  #expect(busiest.hour == 10)
  #expect(JournalAnalytics.busiest([activity(friday, 0)], calendar: utc) == (weekday: nil, hour: nil))
}

@Test func weeksKeepTheTopProjectsAndFoldTheRest() {
  let projects = Dictionary(uniqueKeysWithValues: (1...8).map { ("/p\($0)", $0 * 10) })
  let weeks = JournalAnalytics.weeks([activity(friday, 360, projects: projects), activity(d("2026-10-12"), 0)],
                                     calendar: utc)
  #expect(weeks.map(\.start.key) == ["2026-10-04", "2026-10-11"])
  #expect(weeks[0].projects.map(\.name) == ["/p8", "/p7", "/p6", "/p5", "/p4", "/p3", "Other"])
  #expect(weeks[0].projects.last?.value == 30)
  #expect(weeks[0].focusMinutes == 360)
  #expect(weeks[1].projects.isEmpty)
}

@Test func outputIsCountedPerWeek() {
  func event(_ source: JournalEvent.Source, _ id: String, action: String? = nil) -> JournalEvent {
    JournalEvent(source: source, externalID: id, day: friday, start: at("10:00"), title: id,
                 detail: JournalDetail(action: action))
  }
  let output = JournalAnalytics.output([
    event(.pr, "1", action: "merged"), event(.pr, "2", action: "opened"), event(.review, "3"), event(.review, "4"),
    event(.git, "5"), event(.git, "6"), event(.git, "7"), event(.claude, "8"), event(.note, "9"),
  ], weeks: [d("2026-09-27"), d("2026-10-04")], calendar: utc)
  #expect(output == [
    JournalOutputWeek(start: d("2026-09-27"), merged: 0, reviews: 0, commits: 0, sessions: 0),
    JournalOutputWeek(start: d("2026-10-04"), merged: 1, reviews: 2, commits: 3, sessions: 1),
  ])
}

@Test func skillsAreCountedByMonthForTheTopTags() {
  let now = at("10:00")
  let entries = [
    JournalEntry(day: friday, title: "a", skills: ["ai", "performance"], createdAt: now),
    JournalEntry(day: d("2026-10-02"), title: "b", skills: ["ai"], createdAt: now),
    JournalEntry(day: d("2026-09-30"), title: "c", skills: ["frontend"], createdAt: now),
  ]
  let skills = JournalAnalytics.skills(entries, top: 8)
  #expect(skills.top == [JournalAmount(name: "ai", value: 2), JournalAmount(name: "frontend", value: 1),
                         JournalAmount(name: "performance", value: 1)])
  #expect(skills.months.map(\.month) == ["2026-09", "2026-10"])
  #expect(skills.months[1].skills == [JournalAmount(name: "ai", value: 2), JournalAmount(name: "performance", value: 1)])
  #expect(JournalAnalytics.skills(entries, top: 1).months[0].skills.isEmpty)
}

@Test func theJourneyMarksFirstsStreaksHighlightsAndMonths() {
  let now = at("10:00")
  let entries = [
    JournalEntry(day: d("2026-09-30"), title: "Landing page", skills: ["frontend"], createdAt: now),
    JournalEntry(id: "big", day: friday, title: "Faster startup", impact: "292 s → 40 s", skills: ["ai", "frontend"],
                 createdAt: now),
  ]
  let events = [
    JournalEvent(source: .claude, externalID: "s", day: d("2026-09-30"), start: at("10:00", "2026-09-30"),
                 project: "/code/a", title: "s"),
    JournalEvent(source: .git, externalID: "c", day: friday, start: at("11:00"), project: "/code/b", title: "c"),
  ]
  let active = [d("2026-09-30"), d("2026-10-07"), d("2026-10-08"), friday]
  let journey = JournalAnalytics.journey(entries: entries, events: events, activities: active.map { activity($0, 60) },
                                         qualifying: Set(active), calendar: utc,
                                         name: { $0.split(separator: "/").last.map(String.init) ?? $0 })
  #expect(journey.first?.title == "October 2026")
  #expect(journey.first?.detail == "3 active days · 1 entry · 3 h")
  let titles = journey.map(\.title)
  #expect(titles.contains("Longest streak: 3 days"))
  #expect(titles.contains("Faster startup"))
  #expect(titles.contains("First time: frontend") && titles.contains("First time: ai"))
  #expect(titles.contains("New project: a") && titles.contains("New project: b"))
  #expect(titles.contains("September 2026"))
  #expect(journey.first { $0.title == "First time: frontend" }?.day.key == "2026-09-30")
  #expect(journey.first { $0.kind == .highlight }?.detail == "292 s → 40 s")
}

@Test func insightsPutItTogether() {
  let now = at("10:00")
  let records = [JournalDayRecord(day: friday, minutesByProject: ["/a": 30])]
  let events = [JournalEvent(source: .claude, externalID: "s", day: d("2026-10-08"), start: at("10:00", "2026-10-08"),
                             end: at("11:00", "2026-10-08"), project: "/a", title: "s",
                             detail: JournalDetail(spans: [JournalSpan(start: at("10:00", "2026-10-08"),
                                                                       end: at("11:00", "2026-10-08"))]))]
  let entries = [JournalEntry(day: friday, title: "Shipped", highlight: true, createdAt: now)]
  let insights = JournalAnalytics.insights(range: .days30, today: friday, records: records, events: events,
                                           entries: entries, calendar: utc, name: { $0 })
  #expect(insights.activeDays == 2)
  #expect(insights.currentStreak == 2)
  #expect(insights.grid.count == 53)
  #expect(insights.focusMinutes == 90)
  #expect(insights.impact.map(\.title) == ["Shipped"])
  #expect(insights.weeks.first?.start == JournalAnalytics.weekStart(d("2026-09-10"), calendar: utc))
  #expect(!insights.journey.isEmpty)
}
