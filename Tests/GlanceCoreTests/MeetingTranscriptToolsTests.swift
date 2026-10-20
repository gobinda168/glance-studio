import Foundation
import Testing
@testable import GlanceCore

@Suite struct MeetingTranscriptToolsTests {
  @Test func echoOfTheCallOnTheMicIsDropped() {
    let lines = [
      TranscriptLine(channel: .system, start: 10, end: 14, text: "We should ship the beta on Friday."),
      // The speakers playing that line into the mic, a little late.
      TranscriptLine(channel: .mic, start: 10.4, end: 14.3, text: "we should ship the beta friday"),
      // The user answering.
      TranscriptLine(channel: .mic, start: 15, end: 17, text: "Sounds good, I'll write the release notes."),
      // Same words much later aren't echo.
      TranscriptLine(channel: .mic, start: 60, end: 62, text: "We should ship the beta on Friday."),
    ]
    let kept = EchoFilter.filter(lines)
    #expect(kept.count == 3)
    #expect(!kept.contains { $0.channel == .mic && $0.start == 10.4 })
  }

  @Test func speakersComeFromTheMostOverlappingSpan() {
    let lines = [
      TranscriptLine(channel: .system, start: 0, end: 4, text: "a"),
      TranscriptLine(channel: .system, start: 5, end: 9, text: "b"),
      TranscriptLine(channel: .mic, start: 9, end: 10, text: "c"),
      TranscriptLine(channel: .system, start: 30, end: 31, text: "d"),
    ]
    let spans = [
      SpeakerLabels.Span(speaker: "speaker_7", start: 0, end: 4.5),
      SpeakerLabels.Span(speaker: "speaker_2", start: 4.5, end: 9),
      SpeakerLabels.Span(speaker: "speaker_7", start: 25, end: 28),
    ]
    let labelled = SpeakerLabels.assign(lines, spans: spans)
    #expect(labelled.map(\.speaker) == ["S1", "S2", "you", "S1"])
    #expect(SpeakerLabels.assign(lines, spans: []).map(\.speaker) == ["others", "others", "you", "others"])
  }

  @Test func transcriptMergesASpeakersLinesAndShowsTimes() {
    let record = MeetingRecord(id: "x", title: "T", start: Date(), lines: [
      TranscriptLine(channel: .mic, start: 3, end: 5, text: "Hello"),
      TranscriptLine(channel: .mic, start: 5.5, end: 7, text: "everyone."),
      TranscriptLine(channel: .system, speaker: "S1", start: 65, end: 66, text: "Hi!"),
      TranscriptLine(channel: .system, speaker: "S1", start: 67, end: 68, text: "  "),
    ], speakerNames: ["S1": "Priya"])
    #expect(MeetingTranscript.text(record, you: "Gobinda") == "[0:03] Gobinda: Hello everyone.\n[1:05] Priya: Hi!")
    #expect(MeetingTranscript.clock(3725) == "1:02:05")
  }

  @Test func searchNeedsEveryWord() {
    let record = MeetingRecord(id: "x", title: "Sprint planning", start: Date(),
                               lines: [TranscriptLine(channel: .mic, start: 0, end: 1, text: "Kubernetes upgrade")],
                               summary: MeetingSummary(overview: "Agreed on scope", decisions: ["Ship v2"]))
    #expect(MeetingSearch.matches(record, query: ""))
    #expect(MeetingSearch.matches(record, query: "sprint kubernetes"))
    #expect(MeetingSearch.matches(record, query: "SHIP v2"))
    #expect(!MeetingSearch.matches(record, query: "sprint budget"))
  }

  @Test func markdownHasTheNotesAndOpenItems() {
    let start = Date(timeIntervalSince1970: 1_760_000_000)
    let record = MeetingRecord(id: "x", title: "Design review", start: start, end: start.addingTimeInterval(30 * 60),
                               lines: [TranscriptLine(channel: .mic, start: 0, end: 1, text: "hi")],
                               summary: MeetingSummary(overview: "Reviewed the pill.", decisions: ["Keep the glow"],
                                                       actionItems: [.init(task: "Update MASTER.md", owner: "Gobinda",
                                                                           mine: true),
                                                                     .init(task: "Check contrast")],
                                                       openQuestions: []))
    let markdown = MeetingMarkdown.notes(record, you: "Gobinda")
    #expect(markdown.hasPrefix("## Design review\n"))
    #expect(markdown.contains("30 min · Gobinda"))
    #expect(markdown.contains("### Decisions\n- Keep the glow"))
    #expect(markdown.contains("- [ ] **Gobinda**: Update MASTER.md\n- [ ] Check contrast"))
    #expect(!markdown.contains("Open questions"))
  }

  @Test func parsesTheNotesJSON() throws {
    let reply = """
      Here you go:
      ```json
      {"title": null, "overview": "Planned the sprint.", "decisions": ["Two-week sprint", ""],
       "actionItems": [{"task": "Book the room", "owner": "Priya", "mine": false},
                       {"task": "Write the plan", "owner": "", "mine": true}, {"owner": "x"}],
       "openQuestions": []}
      ```
      """
    let summary = try #require(MeetingNotesPrompt.parse(reply))
    #expect(summary.title == nil)
    #expect(summary.overview == "Planned the sprint.")
    #expect(summary.decisions == ["Two-week sprint"])
    #expect(summary.actionItems == [.init(task: "Book the room", owner: "Priya"),
                                    .init(task: "Write the plan", owner: nil, mine: true)])
    #expect(MeetingNotesPrompt.parse("no json here") == nil)
    #expect(MeetingNotesPrompt.parse(#"{"overview": "  "}"#) == nil)
  }

  @Test func promptsCarryTheTranscriptAndToolsStayOff() {
    let record = MeetingRecord(id: "x", title: "1:1", start: Date(),
                               lines: [TranscriptLine(channel: .mic, start: 0, end: 1, text: "Let's talk goals")])
    let notes = MeetingNotesPrompt.notes(record, you: "Gobinda")
    #expect(notes.contains("[0:00] Gobinda: Let's talk goals"))
    #expect(notes.contains("Meeting: 1:1"))
    let ask = MeetingNotesPrompt.ask("What did I promise?", record: record, you: "Gobinda", live: true)
    #expect(ask.contains("right now"))
    #expect(ask.contains("Question: What did I promise?"))
    let arguments = MeetingNotesPrompt.arguments()
    #expect(arguments.contains("--tools"))
    #expect(arguments[arguments.firstIndex(of: "--tools")! + 1] == "")
  }

  @Test func longTranscriptsKeepBothEnds() {
    let long = String(repeating: "a", count: MeetingNotesPrompt.maxTranscript) + "END"
    let trimmed = MeetingNotesPrompt.trimmed("START" + long)
    #expect(trimmed.hasPrefix("START"))
    #expect(trimmed.hasSuffix("END"))
    #expect(trimmed.contains("left out"))
  }
}
