import Foundation
import Testing
@testable import GlanceCore

@Test func everyConstructorMatchesTheCatalogue() {
  let events: [GlanceEvent] = [
    .meetingEnded(meetingID: "m1", title: "Standup", notesPath: "/n.md"),
    .noticeNew(source: "github", title: "riya", url: ""),
    .ticketMoved(key: "ABC-1", from: "To Do", to: "Done"),
    .prCIFailed(repo: "acme/app", number: 412, sha: "abc"),
    .journalClosed(date: "2026-10-09"),
  ]
  #expect(Set(events.map(\.name)) == Set(AutomationEvents.all.map(\.name)))
  for event in events {
    let fields = AutomationEvents.named(event.name)?.fields ?? []
    #expect(Set(event.payload.object?.keys.map { $0 } ?? []) == Set(fields.map(\.name)), "\(event.name)")
    for field in fields where field.type == "number" {
      guard case .number = event.payload.value(at: [field.name]) else {
        Issue.record("\(event.name).\(field.name) isn't a number")
        continue
      }
    }
  }
}

// Review Focus: an automation triggered on notice.new must not start itself again with its own failure card.
@Test func noticeNewSkipsAutomationsOwnCards() {
  let pr = Notice(id: "1", source: .github, kind: .githubComment, title: "riya", place: nil, preview: "", date: Date(),
                  threadKey: "t", target: .pullRequest(repository: "acme/app", number: 412, path: nil, line: nil))
  #expect(AutomationEventSignals.noticeNew(pr)
    == .noticeNew(source: "github", title: "riya", url: "https://github.com/acme/app/pull/412"))
  let own = AutomationNotices.watcherBroken(name: "A", automation: "a", stderr: "", date: Date())
  #expect(AutomationEventSignals.noticeNew(own) == nil)
  let slack = Notice(id: "2", source: .slack, kind: .slackDM, title: "riya", place: nil, preview: "", date: Date(),
                     threadKey: "s", target: .slack(team: "T", notificationID: nil, channel: nil))
  #expect(AutomationEventSignals.noticeNew(slack)?.payload.value(at: ["url"]) == .string(""))
}

@Test func aMeetingEndsOnceWhenItsNotesAreWritten() {
  var record = MeetingRecord(id: "m1", title: "Standup", start: Date(timeIntervalSince1970: 0), status: .summarizing)
  var fired = Set<String>()
  #expect(AutomationEventSignals.meetingEnded(record, notesPath: "/n.md", fired: &fired) == nil)
  record.status = .ready
  #expect(AutomationEventSignals.meetingEnded(record, notesPath: "/n.md", fired: &fired) == nil)  // no notes
  record.summary = MeetingSummary(overview: "We shipped.")
  #expect(AutomationEventSignals.meetingEnded(record, notesPath: "/n.md", fired: &fired)
    == .meetingEnded(meetingID: "m1", title: "Standup", notesPath: "/n.md"))
  #expect(AutomationEventSignals.meetingEnded(record, notesPath: "/n.md", fired: &fired) == nil)
  #expect(AutomationEventSignals.meetingEnded(nil, notesPath: "", fired: &fired) == nil)
}

@Test func aJournalDayClosesTheFirstTimeOnly() {
  let day = JournalDay(key: "2026-10-09")!
  #expect(AutomationEventSignals.journalClosed(day: day, before: .open) == .journalClosed(date: "2026-10-09"))
  #expect(AutomationEventSignals.journalClosed(day: day, before: .failed) != nil)
  #expect(AutomationEventSignals.journalClosed(day: day, before: .drafted) == nil)
  #expect(AutomationEventSignals.journalClosed(day: day, before: .reviewed) == nil)
}

@Test func ciFailsFireOncePerCommitAfterAFirstLook() {
  var tracker = CIFailureTracker()
  // Opening an old red pull request doesn't fire.
  #expect(tracker.observe(repo: "acme/app", number: 1, sha: "a", failing: true) == nil)
  #expect(tracker.observe(repo: "acme/app", number: 1, sha: "a", failing: true) == nil)
  // A new push that fails does, once.
  #expect(tracker.observe(repo: "acme/app", number: 1, sha: "b", failing: true)
    == .prCIFailed(repo: "acme/app", number: 1, sha: "b"))
  #expect(tracker.observe(repo: "acme/app", number: 1, sha: "b", failing: true) == nil)
  // Running, then failing.
  #expect(tracker.observe(repo: "acme/app", number: 2, sha: "c", failing: false) == nil)
  #expect(tracker.observe(repo: "acme/app", number: 2, sha: "c", failing: true)
    == .prCIFailed(repo: "acme/app", number: 2, sha: "c"))
  // Re-run, green, red again on the same commit: already fired for it.
  #expect(tracker.observe(repo: "acme/app", number: 2, sha: "c", failing: false) == nil)
  #expect(tracker.observe(repo: "acme/app", number: 2, sha: "c", failing: true) == nil)
}

@Test func meetingNotesRenderAsMarkdown() {
  var utc = Calendar(identifier: .gregorian)
  utc.timeZone = TimeZone(identifier: "UTC")!
  let record = MeetingRecord(
    id: "m1", title: "Standup", start: Date(timeIntervalSince1970: 1_791_536_400), status: .ready,
    lines: [TranscriptLine(channel: .mic, speaker: "you", start: 0, end: 1, text: "Hi."),
            TranscriptLine(channel: .system, speaker: "S1", start: 1, end: 2, text: "Hello.")],
    speakerNames: ["S1": "Priya"],
    summary: MeetingSummary(overview: "We shipped.", decisions: ["Ship Friday"],
                            actionItems: [.init(task: "Write notes", owner: "Priya")], openQuestions: []))
  #expect(MeetingNotesMarkdown.render(record, calendar: utc) == """
    # Standup

    2026-10-09 09:00

    ## Overview

    We shipped.

    ## Decisions

    - Ship Friday

    ## Action items

    - Write notes (Priya)

    ## Transcript

    **You:** Hi.
    **Priya:** Hello.

    """)
}
