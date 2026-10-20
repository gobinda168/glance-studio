import Foundation
import Testing
@testable import GlanceCore

@Suite struct CallWatchTests {
  private let t0 = Date(timeIntervalSince1970: 1_000_000)

  @Test func knowsCallAppsAndTheirHelpers() {
    #expect(CallApps.name(for: "us.zoom.xos") == "Zoom")
    #expect(CallApps.name(for: "com.google.Chrome.helper") == "Google Chrome")
    #expect(CallApps.name(for: "com.microsoft.teams2") == "Microsoft Teams")
    #expect(CallApps.name(for: "com.apple.WebKit.GPU") == "a browser")
    #expect(CallApps.name(for: "com.superwhisper.macos") == nil)
  }

  @Test func offersOnceTheMicHasBeenInUseForTheDelay() {
    var watch = CallWatch(delay: 5)
    #expect(watch.update(using: ["us.zoom.xos"], now: t0, recording: false, meetingNudgeShowing: false) == .none)
    #expect(watch.update(using: ["us.zoom.xos"], now: t0 + 3, recording: false, meetingNudgeShowing: false) == .none)
    #expect(watch.update(using: ["us.zoom.xos"], now: t0 + 5, recording: false, meetingNudgeShowing: false)
      == .offer(app: "Zoom", since: t0))
    #expect(watch.showing == "Zoom")
    #expect(watch.update(using: ["us.zoom.xos"], now: t0 + 7, recording: false, meetingNudgeShowing: false) == .none)
  }

  @Test func ignoresAppsThatArentCalls() {
    var watch = CallWatch(delay: 5)
    _ = watch.update(using: ["com.superwhisper.macos"], now: t0, recording: false, meetingNudgeShowing: false)
    #expect(watch.update(using: ["com.superwhisper.macos"], now: t0 + 60, recording: false, meetingNudgeShowing: false)
      == .none)
  }

  @Test func withdrawsWhenTheCallEndsOrRecordingStarts() {
    var watch = CallWatch(delay: 5)
    _ = watch.update(using: ["us.zoom.xos"], now: t0, recording: false, meetingNudgeShowing: false)
    _ = watch.update(using: ["us.zoom.xos"], now: t0 + 5, recording: false, meetingNudgeShowing: false)
    #expect(watch.update(using: [], now: t0 + 6, recording: false, meetingNudgeShowing: false) == .withdraw)
    _ = watch.update(using: ["com.tinyspeck.slackmacgap"], now: t0 + 10, recording: false, meetingNudgeShowing: false)
    #expect(watch.update(using: ["com.tinyspeck.slackmacgap"], now: t0 + 15, recording: false,
                         meetingNudgeShowing: false) == .offer(app: "Slack", since: t0 + 10))
    #expect(watch.update(using: ["com.tinyspeck.slackmacgap"], now: t0 + 16, recording: true,
                         meetingNudgeShowing: false) == .withdraw)
  }

  @Test func aDismissedCallStaysQuietUntilItEnds() {
    var watch = CallWatch(delay: 5)
    _ = watch.update(using: ["us.zoom.xos"], now: t0, recording: false, meetingNudgeShowing: false)
    _ = watch.update(using: ["us.zoom.xos"], now: t0 + 5, recording: false, meetingNudgeShowing: false)
    watch.dismiss()
    #expect(watch.update(using: ["us.zoom.xos"], now: t0 + 60, recording: false, meetingNudgeShowing: false) == .none)
    // The call ends and a new one starts: offered again.
    _ = watch.update(using: [], now: t0 + 70, recording: false, meetingNudgeShowing: false)
    _ = watch.update(using: ["us.zoom.xos"], now: t0 + 80, recording: false, meetingNudgeShowing: false)
    #expect(watch.update(using: ["us.zoom.xos"], now: t0 + 85, recording: false, meetingNudgeShowing: false)
      == .offer(app: "Zoom", since: t0 + 80))
  }

  @Test func waitsWhileRecordingOrWhileTheMeetingNudgeShows() {
    var watch = CallWatch(delay: 5)
    _ = watch.update(using: ["us.zoom.xos"], now: t0, recording: true, meetingNudgeShowing: false)
    #expect(watch.update(using: ["us.zoom.xos"], now: t0 + 10, recording: true, meetingNudgeShowing: false) == .none)
    #expect(watch.update(using: ["us.zoom.xos"], now: t0 + 11, recording: false, meetingNudgeShowing: true) == .none)
    #expect(watch.update(using: ["us.zoom.xos"], now: t0 + 12, recording: false, meetingNudgeShowing: false)
      == .offer(app: "Zoom", since: t0))
  }

  @Test func todayListsWhatsLiveAndStillToCome() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let now = Date(timeIntervalSince1970: 1_760_000_000) // 08:53 UTC
    func event(_ id: String, _ start: TimeInterval, _ minutes: TimeInterval, allDay: Bool = false,
               declined: Bool = false, calendarID: String = "work") -> MeetingEvent {
      MeetingEvent(id: id, calendarID: calendarID, calendarTitle: "Work", title: id, start: now + start,
                   end: now + start + minutes * 60, isAllDay: allDay, declined: declined, link: nil)
    }
    let list = TodayMeetings.list([
      event("later", 3600, 30), event("done", -7200, 30), event("live", -600, 30), event("allday", -3600, 1440,
                                                                                         allDay: true),
      event("no", 600, 30, declined: true), event("off", 900, 30, calendarID: "home"), event("tomorrow", 86_400, 30),
    ], now: now, calendar: calendar, calendarsOff: ["home"])
    #expect(list.map(\.id) == ["live", "later"])
    #expect(TodayMeetings.isLive(list[0], now: now))
    #expect(!TodayMeetings.isLive(list[1], now: now))
  }
}
