import Foundation
import Testing
@testable import GlanceCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func event(_ title: String, in minutes: Double, length: Double = 30, calendar: String = "work",
                   allDay: Bool = false, declined: Bool = false, id: String? = nil) -> MeetingEvent {
  let start = t0.addingTimeInterval(minutes * 60)
  return MeetingEvent(id: MeetingEvent.occurrenceID(eventID: id ?? title, start: start), calendarID: calendar,
                      calendarTitle: "Work", title: title, start: start, end: start.addingTimeInterval(length * 60),
                      isAllDay: allDay, declined: declined, link: nil)
}

private let all = MeetingAgenda.Settings(calendarsOff: [])

@Test func aMeetingIsDueWhenItStarts() {
  let standup = event("Standup", in: 0)
  #expect(MeetingAgenda.due([standup], now: t0, settings: all, state: .init()) == standup)
  #expect(MeetingAgenda.due([standup], now: t0.addingTimeInterval(-1), settings: all, state: .init()) == nil)
}

@Test func aMeetingPastItsCutoffIsNotDue() {
  let standup = event("Standup", in: -10)
  #expect(MeetingAgenda.due([standup], now: t0, settings: all, state: .init()) == nil)
  #expect(MeetingAgenda.due([standup], now: t0.addingTimeInterval(-1), settings: all, state: .init()) == standup)
}

@Test func allDayDeclinedAndCalendarsOffAreSkipped() {
  let events = [event("Holiday", in: -1, allDay: true), event("Nope", in: -1, declined: true),
                event("Team", in: -1, calendar: "team")]
  let settings = MeetingAgenda.Settings(calendarsOff: ["team"])
  #expect(MeetingAgenda.due(events, now: t0, settings: settings, state: .init()) == nil)
}

@Test func aClosedMeetingStaysPendingButIsNotDue() {
  let standup = event("Standup", in: -1)
  let state = MeetingAgenda.State(closed: [standup.id], done: [])
  #expect(MeetingAgenda.due([standup], now: t0, settings: all, state: state) == nil)
  #expect(MeetingAgenda.pending([standup], now: t0, settings: all, state: state) == [standup])
}

@Test func aDoneMeetingIsNeitherDueNorPending() {
  let standup = event("Standup", in: -1)
  let state = MeetingAgenda.State(closed: [], done: [standup.id])
  #expect(MeetingAgenda.due([standup], now: t0, settings: all, state: state) == nil)
  #expect(MeetingAgenda.pending([standup], now: t0, settings: all, state: state).isEmpty)
}

@Test func backToBackMeetingsComeSoonestFirst() {
  let late = event("B review", in: 0)
  let early = event("Overrun", in: -5)
  let tie = event("A review", in: 0)
  #expect(MeetingAgenda.pending([late, tie, early], now: t0, settings: all, state: .init()) == [early, tie, late])
  let done = MeetingAgenda.State(closed: [], done: [early.id])
  #expect(MeetingAgenda.due([late, tie, early], now: t0, settings: all, state: done) == tie)
}

@Test func occurrencesOfARepeatingMeetingAreSeparate() {
  let today = event("Standup", in: 0, id: "series")
  let tomorrow = event("Standup", in: 24 * 60, id: "series")
  #expect(today.id != tomorrow.id)
  let state = MeetingAgenda.State(closed: [], done: [today.id])
  let later = t0.addingTimeInterval(24 * 3600)
  #expect(MeetingAgenda.due([today, tomorrow], now: later, settings: all, state: state) == tomorrow)
}

@Test func wakeTimesAreTheStartThenTheCutoff() {
  let standup = event("Standup", in: 10)
  #expect(MeetingAgenda.nextWake([standup], now: t0, settings: all, state: .init()) == t0.addingTimeInterval(10 * 60))
  let inside = t0.addingTimeInterval(11 * 60)
  #expect(MeetingAgenda.nextWake([standup], now: inside, settings: all, state: .init()) == t0.addingTimeInterval(20 * 60))
}

@Test func wakeTimesSkipThePast() {
  let old = event("Old", in: -30)
  #expect(MeetingAgenda.nextWake([old], now: t0, settings: all, state: .init()) == nil)
  #expect(MeetingAgenda.nextWake([event("Holiday", in: 5, allDay: true)], now: t0, settings: all, state: .init()) == nil)
}

@Test func doneLastsAtLeastTheCutoff() {
  let short = event("Quick", in: 0, length: 5)
  #expect(MeetingAgenda.doneUntil(short) == t0.addingTimeInterval(10 * 60))
  let long = event("Long", in: 0, length: 60)
  #expect(MeetingAgenda.doneUntil(long) == long.end)
}

@Test func theCountdownSaysWhenItStarted() {
  #expect(MeetingAgenda.countdown(start: t0.addingTimeInterval(20), now: t0) == "Starting now")
  #expect(MeetingAgenda.countdown(start: t0.addingTimeInterval(-50), now: t0) == "Starting now")
  #expect(MeetingAgenda.countdown(start: t0.addingTimeInterval(-185), now: t0) == "Started 3 min ago")
}

@Test func anEventKeepsItsICalUID() {
  let start = t0
  let event = MeetingEvent(id: "x", calendarID: "work", calendarTitle: "Work", title: "Sync", start: start,
                           end: start.addingTimeInterval(1800), isAllDay: false, declined: false, link: nil,
                           iCalUID: "abc@google.com")
  #expect(event.iCalUID == "abc@google.com")
  #expect(event.id == "x")
}
