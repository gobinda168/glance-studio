import Foundation

/// Where meetings live (spec 2026-10-09-meeting-notes-design.md, "Privacy"): a folder per meeting with `meeting.json`
/// and, until the notes are done (or for good with Keep recordings), `mic.caf` and `system.caf`.
public struct MeetingNotesStore: Sendable {
  public let folder: URL

  public init(folder: URL) {
    self.folder = folder
  }

  /// `~/Library/Application Support/Glance/Meetings`.
  public static var standard: MeetingNotesStore {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return MeetingNotesStore(folder: support.appendingPathComponent("Glance/Meetings", isDirectory: true))
  }

  public func directory(_ id: String) -> URL {
    folder.appendingPathComponent(id, isDirectory: true)
  }

  public func audioURL(_ id: String, channel: TranscriptLine.Channel) -> URL {
    directory(id).appendingPathComponent("\(channel.rawValue).caf")
  }

  private func recordURL(_ id: String) -> URL {
    directory(id).appendingPathComponent("meeting.json")
  }

  public func save(_ record: MeetingRecord) throws {
    try FileManager.default.createDirectory(at: directory(record.id), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(record).write(to: recordURL(record.id), options: .atomic)
  }

  public func load(_ id: String) -> MeetingRecord? {
    guard let data = try? Data(contentsOf: recordURL(id)) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(MeetingRecord.self, from: data)
  }

  /// Every meeting, newest first. Folders without a readable `meeting.json` are skipped.
  public func all() -> [MeetingRecord] {
    let ids = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return ids.compactMap(load).sorted { $0.start > $1.start }
  }

  public func delete(_ id: String) throws {
    let url = directory(id)
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }

  /// Removes the audio files, keeping the transcript and notes.
  public func deleteAudio(_ id: String) {
    for channel in [TranscriptLine.Channel.mic, .system] {
      try? FileManager.default.removeItem(at: audioURL(id, channel: channel))
    }
  }

  /// Whether a meeting's audio holds any sound: a CAF of only its 4 KB header was stopped before anything was written.
  public func hasRecordedAudio(_ id: String) -> Bool {
    [TranscriptLine.Channel.mic, .system].contains { channel in
      let size = (try? FileManager.default.attributesOfItem(atPath: audioURL(id, channel: channel).path)[.size]) as? Int
      return (size ?? 0) > 4096
    }
  }

  /// Meetings left part-way by a quit or crash, except `except` (the one recording now). One left `recording` becomes
  /// `interrupted` with its audio kept for Transcribe, or ready with a note when nothing reached its files; one left
  /// finishing becomes ready (or interrupted when it has audio but no transcript). Returns the ones it changed.
  @discardableResult
  public func recoverInterrupted(except: String? = nil, now: Date = Date()) -> [MeetingRecord] {
    var changed: [MeetingRecord] = []
    for var record in all() where record.id != except
      && (record.status == .recording || record.status == .transcribing || record.status == .summarizing) {
      if record.status == .recording {
        record.end = record.end ?? record.lines.map(\.end).max().map { record.start.addingTimeInterval($0) } ?? now
        if hasRecordedAudio(record.id) || !record.lines.isEmpty {
          record.status = .interrupted
          record.problem = "Studio quit while this meeting was recording."
        } else {
          record.status = .ready
          record.problem = "Studio quit before anything was recorded."
          deleteAudio(record.id)
          record.hasAudio = false
        }
      } else {
        record.status = record.lines.isEmpty && record.hasAudio ? .interrupted : .ready
        record.problem = record.summary == nil ? "Studio quit before the notes were written." : nil
      }
      try? save(record)
      changed.append(record)
    }
    return changed
  }
}
