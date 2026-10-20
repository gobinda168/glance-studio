import Foundation
import Testing
@testable import GlanceCore

@Suite struct MeetingNotesStoreTests {
  private func temporaryStore() -> MeetingNotesStore {
    MeetingNotesStore(folder: FileManager.default.temporaryDirectory
      .appendingPathComponent("meetings-\(UUID().uuidString)", isDirectory: true))
  }

  @Test func idsSortByStartAndStayUnique() {
    let start = Date(timeIntervalSince1970: 1_760_000_000)
    let id = MeetingRecord.newID(start: start, random: "AB12")
    #expect(id == "20251009-085320-ab12")
    #expect(MeetingRecord.newID(start: start.addingTimeInterval(60), random: "0000") > id)
  }

  @Test func savesLoadsListsNewestFirstAndDeletes() throws {
    let store = temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.folder) }
    let older = MeetingRecord(id: "a", title: "Standup", start: Date(timeIntervalSince1970: 100), status: .ready,
                              lines: [TranscriptLine(channel: .mic, start: 1, end: 2, text: "Hi")],
                              summary: MeetingSummary(overview: "Quick sync",
                                                      actionItems: [.init(task: "Ship it", owner: "Me", mine: true)]))
    let newer = MeetingRecord(id: "b", title: "Planning", start: Date(timeIntervalSince1970: 200))
    try store.save(older)
    try store.save(newer)
    #expect(store.load("a") == older)
    #expect(store.all().map(\.id) == ["b", "a"])
    try store.delete("a")
    #expect(store.all().map(\.id) == ["b"])
    try store.delete("missing")
  }

  @Test func recoversMeetingsLeftRecording() throws {
    let store = temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.folder) }
    let start = Date(timeIntervalSince1970: 1000)
    try store.save(MeetingRecord(id: "r", title: "Call", start: start,
                                 lines: [TranscriptLine(channel: .system, start: 5, end: 42, text: "Bye")]))
    try store.save(MeetingRecord(id: "s", title: "Done", start: start, status: .summarizing,
                                 lines: [TranscriptLine(channel: .mic, start: 1, end: 2, text: "Hi")]))
    try store.save(MeetingRecord(id: "t", title: "Old", start: start, status: .ready))
    let changed = store.recoverInterrupted(now: start.addingTimeInterval(500))
    #expect(Set(changed.map(\.id)) == ["r", "s"])
    let recording = try #require(store.load("r"))
    #expect(recording.status == .interrupted)
    #expect(recording.end == start.addingTimeInterval(42))
    #expect(store.load("s")?.status == .ready)
    #expect(store.load("s")?.problem != nil)
    #expect(store.load("t")?.problem == nil)
  }

  @Test func recoveryLeavesTheLiveMeetingAndNotesEmptyAudio() throws {
    let store = temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.folder) }
    let start = Date(timeIntervalSince1970: 1000)
    try store.save(MeetingRecord(id: "live", title: "Now", start: start))
    // Quit three seconds in: both files hold only their 4 KB header.
    try store.save(MeetingRecord(id: "empty", title: "Blip", start: start))
    for channel in [TranscriptLine.Channel.mic, .system] {
      try Data(count: 4096).write(to: store.audioURL("empty", channel: channel))
    }
    // Quit later: the call channel has audio.
    try store.save(MeetingRecord(id: "audio", title: "Call", start: start))
    try Data(count: 4096).write(to: store.audioURL("audio", channel: .mic))
    try Data(count: 64_000).write(to: store.audioURL("audio", channel: .system))
    let changed = store.recoverInterrupted(except: "live", now: start.addingTimeInterval(60))
    #expect(Set(changed.map(\.id)) == ["empty", "audio"])
    #expect(store.load("live")?.status == .recording)
    let empty = try #require(store.load("empty"))
    #expect(empty.status == .ready)
    #expect(!empty.hasAudio)
    #expect(empty.problem == "Studio quit before anything was recorded.")
    #expect(!FileManager.default.fileExists(atPath: store.audioURL("empty", channel: .mic).path))
    let audio = try #require(store.load("audio"))
    #expect(audio.status == .interrupted)
    #expect(audio.hasAudio)
    #expect(store.hasRecordedAudio("audio"))
    #expect(!store.hasRecordedAudio("empty"))
  }

  @Test func namesSpeakers() {
    var record = MeetingRecord(id: "x", title: "T", start: Date(), lines: [
      TranscriptLine(channel: .system, speaker: "S2", start: 0, end: 1, text: "a"),
      TranscriptLine(channel: .mic, start: 2, end: 3, text: "b"),
      TranscriptLine(channel: .system, speaker: "S1", start: 4, end: 5, text: "c"),
    ])
    #expect(record.speakers == ["S2", "you", "S1"])
    #expect(record.name(of: "S2") == "Speaker 2")
    #expect(record.name(of: "you", you: "Gobinda") == "Gobinda")
    #expect(record.name(of: "others") == "Others")
    record.speakerNames["S2"] = "Priya"
    #expect(record.name(of: "S2") == "Priya")
  }
}
