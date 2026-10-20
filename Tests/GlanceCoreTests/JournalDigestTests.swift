import Foundation
import Testing
@testable import GlanceCore

private let utc = JournalDay.calendar(timeZone: TimeZone(identifier: "UTC")!)
private let day = JournalDay(key: "2026-10-09")!
private func at(_ time: String) -> Date { JournalTime.parse("2026-10-09T\(time):00Z")! }

private func session(_ id: String, project: String, minutes: Int, prompts: [String] = ["Fix it"],
                     files: [String] = ["a.swift"]) -> JournalEvent {
  JournalEvent(source: .claude, externalID: "\(id):2026-10-09", day: day, start: at("10:00"), end: at("10:40"),
               project: project, title: "Session \(id)",
               detail: JournalDetail(prompts: prompts, files: files, turns: prompts.count, activeMinutes: minutes,
                                     branch: "main"))
}

private func commit(_ hash: String, _ time: String, project: String = "/code/app") -> JournalEvent {
  JournalEvent(source: .git, externalID: hash, day: day, start: at(time), project: project,
               title: "commit \(hash)", detail: JournalDetail(hash: hash, filesChanged: 2, insertions: 10, deletions: 1))
}

private func name(_ path: String) -> String { path.split(separator: "/").last.map(String.init) ?? path }

@Test func theDigestGroupsByProjectMostActiveFirstAndNumbersEveryEvent() {
  let events = [
    commit("c1", "11:00"), session("s1", project: "/code/app", minutes: 30), session("s2", project: "/code/site", minutes: 90),
    JournalEvent(source: .meeting, externalID: "m1", day: day, start: at("15:00"), end: at("15:30"), title: "Standup",
                 detail: JournalDetail(calendar: "Work")),
    JournalEvent(source: .note, externalID: "n1", day: day, start: at("16:20"), title: "Customer call: agreed on X"),
  ]
  let digest = JournalDigest.make(day: day, calendar: utc, events: events, name: name)
  let text = digest.text
  #expect(text.hasPrefix("Journal digest for Friday 9 October 2026 (time zone "))
  let site = text.range(of: "## site — /code/site — 90 active min")!
  let app = text.range(of: "## app — /code/app — 30 active min")!
  #expect(site.lowerBound < app.lowerBound)
  #expect(text.contains("Claude Code session 10:00–10:40 · 90 active min · branch main · \"Session s2\""))
  #expect(text.contains("  - Fix it"))
  #expect(text.contains("  Files changed: a.swift"))
  #expect(text.contains("Commit 11:00 \"commit c1\" (+10 −1, 2 files)"))
  #expect(text.contains("## Meetings"))
  #expect(text.contains("15:00–15:30 Standup (Work)"))
  #expect(text.contains("## Notes"))
  #expect(text.contains("16:20 Customer call: agreed on X"))
  #expect(digest.refs.count == 5)
  #expect(digest.refs["e1"] == "claude:s2:2026-10-09")
  #expect(Set(digest.refs.values) == Set(events.map(\.id)))
  #expect(digest.projects == ["site": "/code/site", "app": "/code/app"])
}

@Test func pullRequestsAndReviewsAreDescribed() {
  let events = [
    JournalEvent(source: .pr, externalID: "P:merged", day: day, start: at("09:00"), project: "/code/app",
                 title: "Add journal", detail: JournalDetail(repository: "o/app", number: 12, action: "merged")),
    JournalEvent(source: .review, externalID: "R", day: day, start: at("09:30"), project: "/code/app",
                 title: "Cache fix", detail: JournalDetail(repository: "o/app", number: 7, reviewState: "changes_requested",
                                                           comments: 2)),
  ]
  let text = JournalDigest.make(day: day, calendar: utc, events: events, name: name).text
  #expect(text.contains("Pull request merged 09:00: #12 \"Add journal\" (o/app)"))
  #expect(text.contains("Review (changes requested, 2 comments) 09:30: #7 \"Cache fix\" (o/app)"))
}

@Test func aLongDayIsTrimmedUnderTheCap() {
  let prompts = (0..<40).map { String(repeating: "p\($0) ", count: 60) }
  var events = (0..<4).map { session("s\($0)", project: "/code/app", minutes: 60, prompts: prompts,
                                     files: (0..<50).map { "Sources/File\($0).swift" }) }
  events += (0..<300).map { commit(String(format: "c%03d", $0), String(format: "%02d:%02d", 8 + $0 / 60, $0 % 60)) }
  let digest = JournalDigest.make(day: day, calendar: utc, events: events, name: name)
  #expect(digest.text.count <= JournalDigest.limit)
  #expect(digest.text.contains("more prompts"))
  #expect(digest.text.contains("## app"))
}

@Test func aDayThatStillWontFitIsCut() {
  let events = (0..<300).map { index in
    JournalEvent(source: .meeting, externalID: "m\(index)", day: day, start: at("10:00"), end: at("10:30"),
                 title: String(repeating: "x", count: 190), detail: JournalDetail(calendar: "Work"))
  }
  let digest = JournalDigest.make(day: day, calendar: utc, events: events, name: name)
  #expect(digest.text.count <= JournalDigest.limit)
  #expect(digest.text.contains("[The rest of the day was cut:"))
}
