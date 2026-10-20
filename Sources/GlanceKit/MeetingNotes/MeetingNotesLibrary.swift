import Combine
import Foundation
import GlanceCore

/// The saved meetings for the Meetings side bar and pages (spec 2026-10-09-meeting-notes-design.md): newest first,
/// with renaming speakers, Ask, Regenerate notes, Transcribe and Delete.
@MainActor
public final class MeetingNotesLibrary: ObservableObject {
  public static let shared = MeetingNotesLibrary()

  @Published public private(set) var records: [MeetingRecord] = []
  /// Meetings with an Ask or Regenerate under way.
  @Published public private(set) var working: Set<String> = []

  private let store = MeetingNotesStore.standard
  private var loaded = false

  private init() {}

  /// Reads the folder once; after that the recorder and the actions keep `records` current.
  public func load() {
    guard !loaded else { return }
    loaded = true
    MeetingRecorder.shared.recover()
    reload()
  }

  public func reload() {
    records = store.all()
  }

  public func record(_ id: String) -> MeetingRecord? {
    if let live = MeetingRecorder.shared.record, live.id == id { return live }
    return records.first { $0.id == id }
  }

  /// The recorder saved a meeting: put it in the list.
  func updated(_ record: MeetingRecord) {
    if let index = records.firstIndex(where: { $0.id == record.id }) {
      records[index] = record
    } else {
      records.insert(record, at: 0)
      records.sort { $0.start > $1.start }
    }
  }

  private func save(_ record: MeetingRecord) {
    try? store.save(record)
    updated(record)
  }

  public func rename(_ id: String, title: String) {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var record = record(id), !trimmed.isEmpty else { return }
    record.title = trimmed
    save(record)
  }

  /// Names a speaker ("S2" → "Priya"); an empty name goes back to "Speaker 2".
  public func renameSpeaker(_ speaker: String, to name: String, in id: String) {
    guard var record = record(id) else { return }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    record.speakerNames[speaker] = trimmed.isEmpty ? nil : trimmed
    save(record)
  }

  public func delete(_ id: String) {
    try? store.delete(id)
    records.removeAll { $0.id == id }
  }

  /// Claude writes the notes again from the transcript.
  public func regenerate(_ id: String) {
    guard let record = record(id), !working.contains(id), !record.lines.isEmpty else { return }
    working.insert(id)
    MeetingNotesWriter.notes(for: record) { [weak self] result in
      guard let self, var record = self.record(id) else { return }
      self.working.remove(id)
      switch result {
      case .success(let summary):
        record.summary = summary
        record.problem = nil
        if record.title == MeetingNotesWriter.untitled, let title = summary.title { record.title = title }
      case .failure(let error):
        record.problem = "Notes not written: \(error.localizedDescription)"
      }
      self.save(record)
    }
  }

  /// A question about a saved meeting; the answer joins its Q&A.
  public func ask(_ question: String, in id: String) {
    let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let record = record(id), !asked.isEmpty, !working.contains(id) else { return }
    working.insert(id)
    MeetingNotesWriter.ask(asked, about: record, live: false) { [weak self] result in
      guard let self, var record = self.record(id) else { return }
      self.working.remove(id)
      let answer = switch result {
      case .success(let text): text
      case .failure(let error): "Couldn't answer: \(error.localizedDescription)"
      }
      record.asks.append(MeetingAsk(question: asked, answer: answer, date: Date()))
      self.save(record)
    }
  }

  /// The audio's folder in Finder (kept recordings).
  public func audioFolder(_ id: String) -> URL { store.directory(id) }
}
