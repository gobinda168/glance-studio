import Foundation
import Testing
@testable import GlanceCore

private let utc = JournalDay.calendar(timeZone: TimeZone(identifier: "UTC")!)
private let october9 = JournalDay(key: "2026-10-09")!.interval(in: utc)
private func at(_ time: String) -> Date { JournalTime.parse("2026-10-09T\(time):00Z")! }

private func meeting(_ id: String, _ start: String, _ end: String, calendar: String = "work", allDay: Bool = false,
                     declined: Bool = false) -> MeetingEvent {
  MeetingEvent(id: id, calendarID: calendar, calendarTitle: "Work", title: "Standup  \(id)", start: at(start),
               end: at(end), isAllDay: allDay, declined: declined, link: nil)
}

@Test func meetingsYouAttendBecomeEvents() {
  let events = JournalMeetings.events([
    meeting("a", "10:00", "10:30"),
    meeting("declined", "11:00", "11:30", declined: true),
    meeting("allday", "00:00", "23:59", allDay: true),
    meeting("off", "12:00", "12:30", calendar: "personal"),
    meeting("short", "13:00", "13:04"),
  ], calendarsOff: ["personal"], range: october9, calendar: utc)
  #expect(events.map(\.externalID) == ["a"])
  #expect(events[0].source == .meeting)
  #expect(events[0].title == "Standup a")
  #expect(events[0].end == at("10:30"))
  #expect(events[0].detail.calendar == "Work")
}

private func run(_ time: String, root: String?, duration: Double? = 30, imported: Bool = false) -> CommandRecord {
  CommandRecord(command: "make", folder: root, start: at(time), duration: duration, exitCode: 0, tab: nil,
                gitRoot: root, branch: nil, imported: imported)
}

@Test func terminalRunsBecomeSpansPerProject() {
  let spans = JournalTerminal.spans([
    run("10:00", root: "/a"), run("10:10", root: "/a"), run("11:00", root: "/a"),
    run("10:05", root: "/b"), run("10:06", root: nil), run("10:07", root: "/a", imported: true),
  ], calendar: utc)
  let day = JournalDay(key: "2026-10-09")!
  #expect(spans[day]?["/a"]?.count == 2)
  #expect(JournalSpans.minutes(spans[day]?["/a"] ?? []) == 12)
  #expect(spans[day]?["/b"]?.count == 1)
  #expect(spans[day]?.keys.sorted() == ["/a", "/b"])
}

private func recorded(_ id: String, _ start: String, _ end: String, eventID: String? = nil,
                      status: MeetingRecord.Status = .ready, overview: String? = "Planned the sprint.") -> MeetingRecord {
  MeetingRecord(id: id, title: "Planning \(id)", start: at(start), end: at(end), eventID: eventID, status: status,
                summary: overview.map {
                  MeetingSummary(overview: $0, actionItems: [.init(task: "Write the plan", mine: true),
                                                             .init(task: "Book a room", owner: "Priya")])
                })
}

@Test func recordedNotesJoinTheirCalendarMeeting() {
  let notes = JournalMeetings.notes([recorded("r", "10:00", "10:30", eventID: "a")])
  #expect(notes["a"] == "Planned the sprint. Mine: Write the plan.")
  let events = JournalMeetings.events([meeting("a", "10:00", "10:30")], calendarsOff: [], range: october9,
                                      calendar: utc, notes: notes)
  #expect(events[0].detail.notes == "Planned the sprint. Mine: Write the plan.")
}

@Test func meetingsRecordedWithoutAnEventBecomeTheirOwnEvents() {
  let events = JournalMeetings.recorded([
    recorded("free", "14:00", "14:40"),
    recorded("linked", "10:00", "10:30", eventID: "a"),
    recorded("live", "15:00", "15:30", status: .recording),
    recorded("yesterday", "09:00", "09:30").moved(by: -86_400),
  ], calendarEventIDs: ["a"], range: october9, calendar: utc)
  #expect(events.map(\.externalID) == ["notes:free"])
  #expect(events[0].source == .meeting)
  #expect(events[0].title == "Planning free")
  #expect(events[0].end == at("14:40"))
  #expect(events[0].detail.notes == "Planned the sprint. Mine: Write the plan.")
}

@Test func theDigestCarriesAMeetingsNotes() {
  let event = JournalMeetings.events([meeting("a", "10:00", "10:30")], calendarsOff: [], range: october9,
                                     calendar: utc, notes: ["a": "Agreed on scope."])[0]
  let digest = JournalDigest.make(day: JournalDay(key: "2026-10-09")!, calendar: utc, events: [event])
  #expect(digest.text.contains("Standup a (Work) — notes: Agreed on scope."))
}

private extension MeetingRecord {
  func moved(by seconds: TimeInterval) -> MeetingRecord {
    var copy = self
    copy.start = start.addingTimeInterval(seconds)
    copy.end = end?.addingTimeInterval(seconds)
    return copy
  }
}
