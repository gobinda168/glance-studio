import Foundation

/// Token usage on disk (spec "Storage"): `usage.sqlite` in WAL mode, every call on the store's own serial queue. A
/// request is kept once by its message id. `files` remembers how far each transcript was read, so a scan reads only
/// what's new. A transcript Claude Code deleted loses its mark, never its rows.
public final class UsageStore: @unchecked Sendable {
  public static let schema = 1

  /// The file was written by a newer Glance: it's left alone, never moved aside.
  public struct NewerSchema: Error, CustomStringConvertible {
    public let found: Int
    public var description: String { "Usage was saved by a newer Glance (schema \(found))." }
  }

  /// How far a transcript was read: `offset` is just past its last complete line; `inode` and `size` tell a grown
  /// file from a replaced or shortened one.
  public struct FileMark: Equatable, Sendable {
    public var offset: Int
    public var inode: Int
    public var size: Int

    public init(offset: Int, inode: Int, size: Int) {
      self.offset = offset
      self.inode = inode
      self.size = size
    }
  }

  public let url: URL
  private let db: SQLiteDatabase
  private let queue = DispatchQueue(label: "dev.glance.usage.store")

  public init(url: URL) throws {
    self.url = url
    db = try SQLiteDatabase(url: url, name: "usage store")
    try queue.sync { try migrate() }
  }

  /// The store at `url`. A file SQLite can't read, or that fails its check, is renamed
  /// `usage-damaged-<seconds>.sqlite` beside it and a fresh store starts; `movedAside` says where it went.
  public static func open(url: URL, now: Date = Date()) throws -> (store: UsageStore, movedAside: URL?) {
    do {
      return (try UsageStore(url: url), nil)
    } catch let newer as NewerSchema {
      throw newer
    } catch {
      let files = FileManager.default
      guard files.fileExists(atPath: url.path) else { throw error }
      let aside = url.deletingLastPathComponent()
        .appendingPathComponent("usage-damaged-\(Int(now.timeIntervalSince1970)).sqlite")
      try files.moveItem(at: url, to: aside)
      for suffix in ["-wal", "-shm"] { try? files.removeItem(atPath: url.path + suffix) }
      return (try UsageStore(url: url), aside)
    }
  }

  private func migrate() throws {
    try db.exec("PRAGMA journal_mode = WAL")
    var check = ""
    try db.query("PRAGMA quick_check", []) { row in
      if check.isEmpty { check = row.text(0) ?? "" }
    }
    guard check == "ok" else { throw SQLiteFailure(description: "The usage store failed its check: \(check)") }
    try db.exec("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)")
    var found: Int?
    try db.query("SELECT value FROM meta WHERE key = 'schema'", []) { found = $0.text(0).flatMap(Int.init) }
    if let found, found > Self.schema { throw NewerSchema(found: found) }
    try db.exec("""
      CREATE TABLE IF NOT EXISTS requests (
        message_id TEXT PRIMARY KEY, time REAL NOT NULL, model TEXT NOT NULL, session_id TEXT NOT NULL,
        project TEXT NOT NULL, subagent INTEGER NOT NULL, fast INTEGER NOT NULL, input INTEGER NOT NULL,
        output INTEGER NOT NULL, cache_write_5m INTEGER NOT NULL, cache_write_1h INTEGER NOT NULL,
        cache_read INTEGER NOT NULL)
      """)
    try db.exec("CREATE INDEX IF NOT EXISTS requests_time ON requests(time)")
    try db.exec("""
      CREATE TABLE IF NOT EXISTS files (
        path TEXT PRIMARY KEY, offset INTEGER NOT NULL, inode INTEGER NOT NULL, size INTEGER NOT NULL)
      """)
    try db.exec("INSERT OR IGNORE INTO meta(key, value) VALUES ('schema', '\(Self.schema)')")
  }

  /// `records` (a request already kept stays as it was) and `path`'s new mark, in one transaction.
  public func save(_ records: [UsageRecord], path: String, mark: FileMark) throws {
    try queue.sync {
      try db.transaction {
        for record in records {
          try db.run("""
            INSERT OR IGNORE INTO requests(message_id, time, model, session_id, project, subagent, fast, input, output,
              cache_write_5m, cache_write_1h, cache_read)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.text(record.messageID), .real(record.time.timeIntervalSince1970), .text(record.model),
                  .text(record.sessionID), .text(record.project), .int(record.subagent ? 1 : 0),
                  .int(record.fast ? 1 : 0), .int(record.input), .int(record.output), .int(record.cacheWrite5m),
                  .int(record.cacheWrite1h), .int(record.cacheRead)])
        }
        try db.run("""
          INSERT INTO files(path, offset, inode, size) VALUES (?, ?, ?, ?)
          ON CONFLICT(path) DO UPDATE SET offset = excluded.offset, inode = excluded.inode, size = excluded.size
          """, [.text(path), .int(mark.offset), .int(mark.inode), .int(mark.size)])
      }
    }
  }

  /// The requests from `from` up to (not including) `to`, oldest first.
  public func records(from: Date, to: Date) throws -> [UsageRecord] {
    try queue.sync {
      var records: [UsageRecord] = []
      try db.query("""
        SELECT message_id, time, model, session_id, project, subagent, fast, input, output, cache_write_5m,
          cache_write_1h, cache_read FROM requests WHERE time >= ? AND time < ? ORDER BY time, message_id
        """, [.real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970)]) { row in
        records.append(UsageRecord(
          messageID: row.text(0) ?? "", time: Date(timeIntervalSince1970: row.double(1)), model: row.text(2) ?? "",
          sessionID: row.text(3) ?? "", project: row.text(4) ?? "", subagent: row.bool(5), fast: row.bool(6),
          input: row.int(7) ?? 0, output: row.int(8) ?? 0, cacheWrite5m: row.int(9) ?? 0,
          cacheWrite1h: row.int(10) ?? 0, cacheRead: row.int(11) ?? 0))
      }
      return records
    }
  }

  /// The oldest request's time: when tracking began.
  public func earliest() throws -> Date? {
    try queue.sync {
      var earliest: Date?
      try db.query("SELECT MIN(time) FROM requests", []) { row in
        earliest = row.real(0).map(Date.init(timeIntervalSince1970:))
      }
      return earliest
    }
  }

  public func marks() throws -> [String: FileMark] {
    try queue.sync {
      var marks: [String: FileMark] = [:]
      try db.query("SELECT path, offset, inode, size FROM files", []) { row in
        guard let path = row.text(0) else { return }
        marks[path] = FileMark(offset: row.int(1) ?? 0, inode: row.int(2) ?? 0, size: row.int(3) ?? 0)
      }
      return marks
    }
  }

  /// Forgets the marks of transcripts that are gone. Their requests stay.
  public func keepMarks(only paths: Set<String>) throws {
    let gone = try marks().keys.filter { !paths.contains($0) }
    guard !gone.isEmpty else { return }
    try queue.sync {
      try db.transaction {
        for path in gone { try db.run("DELETE FROM files WHERE path = ?", [.text(path)]) }
      }
    }
  }
}
