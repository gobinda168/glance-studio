import Foundation

/// One run of a command, as Glance's history keeps it (spec "S2: history").
public struct CommandRecord: Equatable, Sendable {
  public var command: String
  /// Where it ran; nil for an entry imported from `~/.zsh_history`.
  public var folder: String?
  public var start: Date
  public var duration: TimeInterval?
  public var exitCode: Int?
  /// The Studio surface (tab) it ran in.
  public var tab: String?
  public var gitRoot: String?
  public var branch: String?
  public var imported: Bool

  public init(command: String, folder: String?, start: Date, duration: TimeInterval?, exitCode: Int?, tab: String?,
              gitRoot: String?, branch: String?, imported: Bool) {
    self.command = command
    self.folder = folder
    self.start = start
    self.duration = duration
    self.exitCode = exitCode
    self.tab = tab
    self.gitRoot = gitRoot
    self.branch = branch
    self.imported = imported
  }
}

/// What goes into history: not a blank line, not a command typed with a leading space (zsh's "keep this out of
/// history" convention), nothing holding a secret.
public enum HistoryPolicy {
  public static func shouldRecord(_ command: String) -> Bool {
    guard !command.hasPrefix(" "), !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    return !SecretFilter.containsSecret(command)
  }
}

/// Glance's command history on disk: SQLite in WAL mode, every call on the store's own serial queue.
public final class CommandHistoryStore: @unchecked Sendable {
  public typealias Failure = SQLiteFailure

  private let db: SQLiteDatabase
  private let queue = DispatchQueue(label: "dev.glance.history")
  public let url: URL

  public init(url: URL) throws {
    self.url = url
    db = try SQLiteDatabase(url: url, name: "history")
    try queue.sync { try migrate() }
  }

  private func migrate() throws {
    try exec("PRAGMA journal_mode = WAL")
    try exec("""
      CREATE TABLE IF NOT EXISTS commands (
        id INTEGER PRIMARY KEY, command TEXT NOT NULL, folder TEXT, start REAL NOT NULL, duration REAL,
        exit_code INTEGER, tab TEXT, git_root TEXT, branch TEXT, imported INTEGER NOT NULL DEFAULT 0)
      """)
    try exec("CREATE INDEX IF NOT EXISTS commands_start ON commands(start)")
    try exec("""
      CREATE TABLE IF NOT EXISTS picks (
        context TEXT NOT NULL, candidate TEXT NOT NULL, count INTEGER NOT NULL, last REAL NOT NULL,
        PRIMARY KEY(context, candidate))
      """)
    try exec("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)")
    try exec("INSERT OR IGNORE INTO meta(key, value) VALUES ('schema', '1')")
  }

  public func insert(_ record: CommandRecord) throws {
    try queue.sync { try insertRecord(record) }
  }

  private func insertRecord(_ record: CommandRecord) throws {
    try run("""
      INSERT INTO commands(command, folder, start, duration, exit_code, tab, git_root, branch, imported)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      """, [.text(record.command), .text(record.folder), .real(record.start.timeIntervalSince1970),
            .real(record.duration), .int(record.exitCode), .text(record.tab), .text(record.gitRoot),
            .text(record.branch), .int(record.imported ? 1 : 0)])
  }

  /// Many runs in one transaction (the import).
  public func insert(_ records: [CommandRecord]) throws {
    try queue.sync {
      try db.transaction { for record in records { try insertRecord(record) } }
    }
  }

  /// Every run, oldest first.
  public func all() throws -> [CommandRecord] {
    try queue.sync {
      var records: [CommandRecord] = []
      try query("""
        SELECT command, folder, start, duration, exit_code, tab, git_root, branch, imported
        FROM commands ORDER BY start, id
        """, []) { row in
        records.append(Self.record(row))
      }
      return records
    }
  }

  /// The runs that started in `[from, to)`, oldest first (Journal's time estimate).
  public func records(from: Date, to: Date) throws -> [CommandRecord] {
    try queue.sync {
      var records: [CommandRecord] = []
      try query("""
        SELECT command, folder, start, duration, exit_code, tab, git_root, branch, imported
        FROM commands WHERE start >= ? AND start < ? ORDER BY start, id
        """, [.real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970)]) { row in
        records.append(Self.record(row))
      }
      return records
    }
  }

  private static func record(_ row: SQLiteDatabase.Row) -> CommandRecord {
    CommandRecord(command: row.text(0) ?? "", folder: row.text(1), start: Date(timeIntervalSince1970: row.double(2)),
                  duration: row.real(3), exitCode: row.int(4), tab: row.text(5), gitRoot: row.text(6),
                  branch: row.text(7), imported: row.bool(8))
  }

  /// One more pick of `candidate` from the Tab menu in `context` (`CompletionPicks.context`).
  public func recordPick(context: String, candidate: String) throws {
    try queue.sync {
      try run("""
        INSERT INTO picks(context, candidate, count, last) VALUES (?, ?, 1, ?)
        ON CONFLICT(context, candidate) DO UPDATE SET count = count + 1, last = excluded.last
        """, [.text(context), .text(candidate), .real(Date().timeIntervalSince1970)])
    }
  }

  /// Every Tab menu pick: context → candidate → how often.
  public func picks() throws -> [String: [String: Int]] {
    try queue.sync {
      var picks: [String: [String: Int]] = [:]
      try query("SELECT context, candidate, count FROM picks", []) { row in
        picks[row.text(0) ?? "", default: [:]][row.text(1) ?? ""] = row.int(2) ?? 0
      }
      return picks
    }
  }

  /// Every run of `command` (⌘⌫ in the search).
  public func delete(command: String) throws {
    try queue.sync { try run("DELETE FROM commands WHERE command = ?", [.text(command)]) }
  }

  public func deleteAll() throws {
    try queue.sync { try exec("DELETE FROM commands") }
  }

  /// The rows the zsh history import made (before importing again).
  public func deleteImported() throws {
    try queue.sync { try exec("DELETE FROM commands WHERE imported = 1") }
  }

  public func meta(_ key: String) throws -> String? {
    try queue.sync {
      var value: String?
      try query("SELECT value FROM meta WHERE key = ?", [.text(key)]) { value = $0.text(0) }
      return value
    }
  }

  public func setMeta(_ key: String, _ value: String?) throws {
    try queue.sync {
      if let value {
        try run("INSERT INTO meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                [.text(key), .text(value)])
      } else {
        try run("DELETE FROM meta WHERE key = ?", [.text(key)])
      }
    }
  }

  public func count() throws -> Int {
    try queue.sync {
      var count = 0
      try query("SELECT COUNT(*) FROM commands", []) { count = $0.int(0) ?? 0 }
      return count
    }
  }

  // MARK: - SQLite

  private func exec(_ sql: String) throws { try db.exec(sql) }

  private func run(_ sql: String, _ values: [SQLiteDatabase.Value]) throws { try db.run(sql, values) }

  private func query(_ sql: String, _ values: [SQLiteDatabase.Value], row: (SQLiteDatabase.Row) throws -> Void) throws {
    try db.query(sql, values, row: row)
  }
}
