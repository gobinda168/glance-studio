import Foundation

/// Journal on disk (spec 2026-10-09-journal-design.md, "Storage"): `journal.sqlite` in WAL mode, every call on the
/// store's own serial queue. Events are upserted by (source, external id), so collecting a day again never duplicates
/// it; `collected_at` is the first collection, which "new since the recap" counts from.
public final class JournalStore: @unchecked Sendable {
  public static let schema = 1

  /// The file was written by a newer Glance: it's left alone, never moved aside.
  public struct NewerSchema: Error, CustomStringConvertible {
    public let found: Int
    public var description: String { "The journal was written by a newer Glance (schema \(found))." }
  }

  public let url: URL
  private let db: SQLiteDatabase
  private let queue = DispatchQueue(label: "dev.glance.journal.store")

  public init(url: URL) throws {
    self.url = url
    db = try SQLiteDatabase(url: url, name: "journal")
    try queue.sync { try migrate() }
  }

  /// The journal at `url`. A file SQLite can't read, or that fails its check, is renamed
  /// `journal-damaged-<seconds>.sqlite` beside it and a fresh journal starts; `movedAside` says where it went.
  public static func open(url: URL, now: Date = Date()) throws -> (store: JournalStore, movedAside: URL?) {
    do {
      return (try JournalStore(url: url), nil)
    } catch let newer as NewerSchema {
      throw newer
    } catch {
      let files = FileManager.default
      guard files.fileExists(atPath: url.path) else { throw error }
      let aside = url.deletingLastPathComponent()
        .appendingPathComponent("journal-damaged-\(Int(now.timeIntervalSince1970)).sqlite")
      try files.moveItem(at: url, to: aside)
      for suffix in ["-wal", "-shm"] { try? files.removeItem(atPath: url.path + suffix) }
      return (try JournalStore(url: url), aside)
    }
  }

  private func migrate() throws {
    try db.exec("PRAGMA journal_mode = WAL")
    var check = ""
    try db.query("PRAGMA quick_check", []) { row in
      if check.isEmpty { check = row.text(0) ?? "" }
    }
    guard check == "ok" else { throw SQLiteFailure(description: "The journal failed its check: \(check)") }
    try db.exec("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)")
    var found: Int?
    try db.query("SELECT value FROM meta WHERE key = 'schema'", []) { found = $0.text(0).flatMap(Int.init) }
    if let found, found > Self.schema { throw NewerSchema(found: found) }
    try db.exec("""
      CREATE TABLE IF NOT EXISTS events (
        id INTEGER PRIMARY KEY, source TEXT NOT NULL, external_id TEXT NOT NULL, day TEXT NOT NULL,
        start REAL NOT NULL, ends REAL, project TEXT, title TEXT NOT NULL, detail TEXT NOT NULL DEFAULT '{}',
        collected_at REAL NOT NULL, UNIQUE(source, external_id))
      """)
    try db.exec("CREATE INDEX IF NOT EXISTS events_day ON events(day)")
    try db.exec("""
      CREATE TABLE IF NOT EXISTS days (
        day TEXT PRIMARY KEY, status TEXT NOT NULL DEFAULT 'open', headline TEXT NOT NULL DEFAULT '',
        recap_md TEXT NOT NULL DEFAULT '', minutes_by_project TEXT NOT NULL DEFAULT '{}', generated_at REAL,
        reviewed_at REAL, error TEXT, source_notes TEXT NOT NULL DEFAULT '{}',
        terminal_spans TEXT NOT NULL DEFAULT '{}')
      """)
    try db.exec("""
      CREATE TABLE IF NOT EXISTS entries (
        id TEXT PRIMARY KEY, day TEXT NOT NULL, position INTEGER NOT NULL, title TEXT NOT NULL,
        summary TEXT NOT NULL, project TEXT, kind TEXT NOT NULL, impact TEXT NOT NULL, challenge TEXT NOT NULL,
        approach TEXT NOT NULL, outcome TEXT NOT NULL, lesson TEXT NOT NULL, skills TEXT NOT NULL,
        minutes INTEGER NOT NULL, highlight INTEGER NOT NULL, public_draft TEXT NOT NULL, event_ids TEXT NOT NULL,
        edited INTEGER NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL)
      """)
    try db.exec("CREATE INDEX IF NOT EXISTS entries_day ON entries(day)")
    try db.exec("INSERT OR IGNORE INTO meta(key, value) VALUES ('schema', '\(Self.schema)')")
  }

  // MARK: Events

  public func upsert(_ events: [JournalEvent], now: Date = Date()) throws {
    guard !events.isEmpty else { return }
    try queue.sync {
      try db.transaction {
        for event in events {
          try db.run("""
            INSERT INTO events(source, external_id, day, start, ends, project, title, detail, collected_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source, external_id) DO UPDATE SET day = excluded.day, start = excluded.start,
              ends = excluded.ends, project = excluded.project, title = excluded.title, detail = excluded.detail
            """, [.text(event.source.rawValue), .text(event.externalID), .text(event.day.key),
                  .real(event.start.timeIntervalSince1970), .real(event.end?.timeIntervalSince1970),
                  .text(event.project), .text(event.title), .text(Self.json(event.detail)),
                  .real(now.timeIntervalSince1970)])
          try db.run("INSERT OR IGNORE INTO days(day) VALUES (?)", [.text(event.day.key)])
        }
      }
    }
  }

  public func events(on day: JournalDay) throws -> [JournalEvent] {
    try events(from: day, through: day)
  }

  public func events(from: JournalDay, through: JournalDay) throws -> [JournalEvent] {
    try queue.sync {
      var events: [JournalEvent] = []
      try db.query("""
        SELECT source, external_id, day, start, ends, project, title, detail FROM events
        WHERE day >= ? AND day <= ? ORDER BY start, id
        """, [.text(from.key), .text(through.key)]) { row in
        guard let source = row.text(0).flatMap(JournalEvent.Source.init(rawValue:)),
              let day = row.text(2).flatMap(JournalDay.init(key:)) else { return }
        events.append(JournalEvent(
          source: source, externalID: row.text(1) ?? "", day: day, start: Date(timeIntervalSince1970: row.double(3)),
          end: row.real(4).map(Date.init(timeIntervalSince1970:)), project: row.text(5), title: row.text(6) ?? "",
          detail: Self.decode(JournalDetail.self, row.text(7)) ?? JournalDetail()))
      }
      return events
    }
  }

  /// Removes one event by `JournalEvent.id` (a note the user deleted).
  public func deleteEvent(id: String) throws {
    let parts = id.split(separator: ":", maxSplits: 1)
    guard parts.count == 2 else { return }
    try queue.sync {
      try db.run("DELETE FROM events WHERE source = ? AND external_id = ?",
                 [.text(String(parts[0])), .text(String(parts[1]))])
    }
  }

  // MARK: Days

  private static let recordColumns = """
    day, status, headline, recap_md, minutes_by_project, generated_at, reviewed_at, error, source_notes, terminal_spans
    """

  public func record(_ day: JournalDay) throws -> JournalDayRecord? {
    try queue.sync {
      var found: JournalDayRecord?
      try db.query("SELECT \(Self.recordColumns) FROM days WHERE day = ?", [.text(day.key)]) { found = Self.record($0) }
      return found
    }
  }

  /// Every day, oldest first.
  public func records() throws -> [JournalDayRecord] {
    try queue.sync {
      var records: [JournalDayRecord] = []
      try db.query("SELECT \(Self.recordColumns) FROM days ORDER BY day", []) { row in
        if let record = Self.record(row) { records.append(record) }
      }
      return records
    }
  }

  public func save(_ record: JournalDayRecord) throws {
    try queue.sync { try saveRecord(record) }
  }

  private func saveRecord(_ record: JournalDayRecord) throws {
    try db.run("""
      INSERT INTO days(\(Self.recordColumns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(day) DO UPDATE SET status = excluded.status, headline = excluded.headline,
        recap_md = excluded.recap_md, minutes_by_project = excluded.minutes_by_project,
        generated_at = excluded.generated_at, reviewed_at = excluded.reviewed_at, error = excluded.error,
        source_notes = excluded.source_notes, terminal_spans = excluded.terminal_spans
      """, [.text(record.day.key), .text(record.status.rawValue), .text(record.headline), .text(record.recap),
            .text(Self.json(record.minutesByProject)), .real(record.generatedAt?.timeIntervalSince1970),
            .real(record.reviewedAt?.timeIntervalSince1970), .text(record.error), .text(Self.json(record.sourceNotes)),
            .text(Self.json(record.terminal))])
  }

  private static func record(_ row: SQLiteDatabase.Row) -> JournalDayRecord? {
    guard let day = row.text(0).flatMap(JournalDay.init(key:)) else { return nil }
    return JournalDayRecord(
      day: day, status: row.text(1).flatMap(JournalDayRecord.Status.init(rawValue:)) ?? .open,
      headline: row.text(2) ?? "", recap: row.text(3) ?? "",
      minutesByProject: decode([String: Int].self, row.text(4)) ?? [:],
      generatedAt: row.real(5).map(Date.init(timeIntervalSince1970:)),
      reviewedAt: row.real(6).map(Date.init(timeIntervalSince1970:)), error: row.text(7),
      sourceNotes: decode([String: String].self, row.text(8)) ?? [:],
      terminal: decode([String: [JournalSpan]].self, row.text(9)) ?? [:])
  }

  /// Every day for the side bar, newest first.
  public func summaries() throws -> [JournalDaySummary] {
    try queue.sync {
      var summaries: [JournalDaySummary] = []
      try db.query("""
        SELECT d.day, d.status, d.headline,
          (SELECT COUNT(*) FROM events e WHERE e.day = d.day),
          (SELECT COUNT(*) FROM entries n WHERE n.day = d.day),
          (SELECT COUNT(*) FROM events e WHERE e.day = d.day AND d.generated_at IS NOT NULL
             AND e.collected_at > d.generated_at)
        FROM days d ORDER BY d.day DESC
        """, []) { row in
        guard let day = row.text(0).flatMap(JournalDay.init(key:)) else { return }
        summaries.append(JournalDaySummary(
          day: day, status: row.text(1).flatMap(JournalDayRecord.Status.init(rawValue:)) ?? .open,
          headline: row.text(2) ?? "", eventCount: row.int(3) ?? 0, entryCount: row.int(4) ?? 0,
          newSinceRecap: row.int(5) ?? 0))
      }
      return summaries
    }
  }

  /// The days whose headline, recap, or entries' titles and summaries contain `text` (any case), newest first: the
  /// side bar's filter.
  public func days(matching text: String) throws -> [JournalDay] {
    let pattern = "%" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_") + "%"
    return try queue.sync {
      var days: [JournalDay] = []
      try db.query("""
        SELECT day FROM days WHERE headline LIKE ?1 ESCAPE '\\' OR recap_md LIKE ?1 ESCAPE '\\'
        UNION SELECT day FROM entries WHERE title LIKE ?1 ESCAPE '\\' OR summary LIKE ?1 ESCAPE '\\'
        ORDER BY day DESC
        """, [.text(pattern)]) { row in
        if let day = row.text(0).flatMap(JournalDay.init(key:)) { days.append(day) }
      }
      return days
    }
  }

  // MARK: Entries

  private static let entryColumns = """
    id, day, position, title, summary, project, kind, impact, challenge, approach, outcome, lesson, skills, minutes,
    highlight, public_draft, event_ids, edited, created_at, updated_at
    """

  public func entries(on day: JournalDay) throws -> [JournalEntry] {
    try entries(from: day, through: day)
  }

  public func entries(from: JournalDay, through: JournalDay) throws -> [JournalEntry] {
    try queue.sync {
      var entries: [JournalEntry] = []
      try db.query("SELECT \(Self.entryColumns) FROM entries WHERE day >= ? AND day <= ? ORDER BY day, position, created_at",
                   [.text(from.key), .text(through.key)]) { row in
        guard let day = row.text(1).flatMap(JournalDay.init(key:)) else { return }
        entries.append(JournalEntry(
          id: row.text(0) ?? UUID().uuidString, day: day, position: row.int(2) ?? 0, title: row.text(3) ?? "",
          summary: row.text(4) ?? "", project: row.text(5),
          kind: row.text(6).flatMap(JournalEntry.Kind.init(rawValue:)) ?? .other, impact: row.text(7) ?? "",
          challenge: row.text(8) ?? "", approach: row.text(9) ?? "", outcome: row.text(10) ?? "",
          lesson: row.text(11) ?? "", skills: Self.decode([String].self, row.text(12)) ?? [],
          minutes: row.int(13) ?? 0, highlight: row.bool(14), publicDraft: row.text(15) ?? "",
          eventIDs: Self.decode([String].self, row.text(16)) ?? [], edited: row.bool(17),
          createdAt: Date(timeIntervalSince1970: row.double(18)), updatedAt: Date(timeIntervalSince1970: row.double(19))))
      }
      return entries
    }
  }

  public func save(_ entry: JournalEntry) throws {
    try queue.sync { try saveEntry(entry) }
  }

  private func saveEntry(_ entry: JournalEntry) throws {
    try db.run("""
      INSERT OR REPLACE INTO entries(\(Self.entryColumns))
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """, [.text(entry.id), .text(entry.day.key), .int(entry.position), .text(entry.title), .text(entry.summary),
            .text(entry.project), .text(entry.kind.rawValue), .text(entry.impact), .text(entry.challenge),
            .text(entry.approach), .text(entry.outcome), .text(entry.lesson), .text(Self.json(entry.skills)),
            .int(entry.minutes), .int(entry.highlight ? 1 : 0), .text(entry.publicDraft),
            .text(Self.json(entry.eventIDs)), .int(entry.edited ? 1 : 0),
            .real(entry.createdAt.timeIntervalSince1970), .real(entry.updatedAt.timeIntervalSince1970)])
  }

  public func deleteEntry(id: String) throws {
    try queue.sync { try db.run("DELETE FROM entries WHERE id = ?", [.text(id)]) }
  }

  /// A new draft in one go: the day's entries become `entries` (already merged with the ones to keep, see
  /// `JournalRecap.merge`) and its record becomes `record`.
  public func replaceEntries(on day: JournalDay, with entries: [JournalEntry], record: JournalDayRecord) throws {
    try queue.sync {
      try db.transaction {
        try db.run("DELETE FROM entries WHERE day = ?", [.text(day.key)])
        for entry in entries { try saveEntry(entry) }
        try saveRecord(record)
      }
    }
  }

  // MARK: Deleting

  /// The day's events, entries and recap; the space is given back.
  public func deleteDay(_ day: JournalDay) throws {
    try queue.sync {
      try db.transaction {
        for table in ["events", "entries", "days"] {
          try db.run("DELETE FROM \(table) WHERE day = ?", [.text(day.key)])
        }
      }
      try db.exec("VACUUM")
    }
  }

  /// Everything but the schema version, with the file and its write-ahead log emptied, so nothing of it stays on disk.
  public func deleteAll() throws {
    try queue.sync {
      try db.transaction {
        for table in ["events", "entries", "days"] { try db.exec("DELETE FROM \(table)") }
        try db.exec("DELETE FROM meta WHERE key != 'schema'")
      }
      try db.exec("VACUUM")
      try db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
    }
  }

  // MARK: Meta

  public func meta(_ key: String) throws -> String? {
    try queue.sync {
      var value: String?
      try db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]) { value = $0.text(0) }
      return value
    }
  }

  public func setMeta(_ key: String, _ value: String?) throws {
    try queue.sync {
      if let value {
        try db.run("INSERT INTO meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                   [.text(key), .text(value)])
      } else {
        try db.run("DELETE FROM meta WHERE key = ?", [.text(key)])
      }
    }
  }

  // MARK: JSON columns

  private static func json<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = .sortedKeys
    return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
  }

  private static func decode<T: Decodable>(_ type: T.Type, _ text: String?) -> T? {
    guard let text else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return try? decoder.decode(type, from: Data(text.utf8))
  }
}
