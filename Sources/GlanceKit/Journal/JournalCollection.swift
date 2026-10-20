import Foundation
import GlanceCore

/// One Journal collection pass over some days: the collectors, then the store (events, each day's notes). The helper
/// runs it (`JournalJob`), or the app when the helper is down. Blocks until done.
public enum JournalCollection {
  /// Collects `input.days` into `store` and returns the days' summaries.
  public static func run(_ input: JournalCollector.Input, in store: JournalStore) throws -> [JournalDaySummary] {
    let outcome = JournalCollector.collect(input)
    try store.upsert(outcome.events)
    for day in input.days {
      guard var record = try store.record(day) else { continue }
      record.sourceNotes = outcome.notes
      if input.sources.contains(.terminal) { record.terminal = outcome.terminal[day] ?? [:] }
      try store.save(record)
    }
    return try store.summaries()
  }
}

/// What the app tells the helper to collect: `JournalCollector.Input` without the Mac-side parts the helper can read
/// itself (the calendar, home folder, transcript and history paths, and the meeting notes).
public struct JournalCollectRequest: Codable, Sendable {
  public var days: [JournalDay]
  public var sources: Set<JournalSource>
  public var folders: [String]
  public var repositoryFolders: [String: String]
  public var meetings: [MeetingEvent]
  public var calendarAllowed: Bool
  public var calendarsOff: Set<String>
  /// Meeting Notes' recordings join the meetings (the helper reads them from disk).
  public var withMeetingNotes: Bool

  public init(_ input: JournalCollector.Input) {
    days = input.days
    sources = input.sources
    folders = input.folders
    repositoryFolders = input.repositoryFolders
    meetings = input.meetings
    calendarAllowed = input.calendarAllowed
    calendarsOff = input.calendarsOff
    withMeetingNotes = !input.meetingNotes.isEmpty
  }

  /// The collector's input on this Mac.
  public func input(history: URL) -> JournalCollector.Input {
    let home = NSHomeDirectory()
    return JournalCollector.Input(
      days: days, calendar: JournalDay.calendar(), sources: sources, folders: folders,
      repositoryFolders: repositoryFolders, meetings: meetings, calendarAllowed: calendarAllowed,
      calendarsOff: calendarsOff, home: home,
      claudeProjects: URL(fileURLWithPath: home).appendingPathComponent(".claude/projects"), history: history,
      meetingNotes: withMeetingNotes ? MeetingNotesStore.standard.all() : [])
  }
}

/// Journal's collection in the helper: one pass at a time, in the order asked, each answered with
/// `journalCollected` once its days are in `journal.sqlite`. The app reads the summaries from the file.
public final class JournalJob: @unchecked Sendable {
  private let queue = DispatchQueue(label: "dev.glance.journal.job", qos: .utility)
  private let emit: @Sendable (HelperWire.Event) -> Void
  private var store: JournalStore?

  public init(emit: @escaping @Sendable (HelperWire.Event) -> Void) {
    self.emit = emit
  }

  public func collect(id: Int, json: String) {
    queue.async { [self] in
      guard let request = try? JSONDecoder().decode(JournalCollectRequest.self, from: Data(json.utf8)),
            let store = openStore() else { return emit(.journalCollected(id: id, ok: false)) }
      let history = JournalService.folder.appendingPathComponent("history.sqlite")
      let ok = (try? JournalCollection.run(request.input(history: history), in: store)) != nil
      emit(.journalCollected(id: id, ok: ok))
    }
  }

  private func openStore() -> JournalStore? {
    if store == nil {
      store = (try? JournalStore.open(url: JournalService.folder.appendingPathComponent("journal.sqlite")))?.store
    }
    return store
  }
}
