import Foundation
import Testing
@testable import GlanceCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@Test func aMeetingSaysWhenItStarts() {
  #expect(NudgeSpeech.meeting(name: "Gobinda", title: "Sprint planning", start: t0.addingTimeInterval(120), now: t0)
    == "Hey Gobinda, Sprint planning starts in 2 minutes.")
  #expect(NudgeSpeech.meeting(name: "Gobinda", title: "Standup", start: t0.addingTimeInterval(45), now: t0)
    == "Hey Gobinda, Standup starts in 1 minute.")
  #expect(NudgeSpeech.meeting(name: "Gobinda", title: "Standup", start: t0.addingTimeInterval(10), now: t0)
    == "Hey Gobinda, Standup is starting now.")
  #expect(NudgeSpeech.meeting(name: "Gobinda", title: "Standup", start: t0.addingTimeInterval(-200), now: t0)
    == "Hey Gobinda, Standup has started.")
}

@Test func anUntitledMeetingIsYourMeeting() {
  #expect(NudgeSpeech.meeting(name: "Gobinda", title: "Untitled meeting", start: t0.addingTimeInterval(300), now: t0)
    == "Hey Gobinda, you have a meeting in 5 minutes.")
  #expect(NudgeSpeech.meeting(name: "Gobinda", title: " ", start: t0, now: t0) == "Hey Gobinda, your meeting is starting now.")
  #expect(NudgeSpeech.meeting(name: "Gobinda", title: "", start: t0.addingTimeInterval(-120), now: t0)
    == "Hey Gobinda, your meeting has started.")
}

@Test func withoutANameItJustSaysHey() {
  #expect(NudgeSpeech.meeting(name: nil, title: "Standup", start: t0.addingTimeInterval(120), now: t0)
    == "Hey, Standup starts in 2 minutes.")
}
