import Foundation

/// A page in the Browser's history.
public struct HistoryEntry: Equatable, Sendable {
  public let url: URL
  public let title: String
  public let visits: Int
  public let lastVisit: Date
}

/// The Browser's history (spec 2026-10-10-browser-design.md, "Sessions and data"): one row per address with its
/// title, visits and last visit, in SQLite on this Mac only; only http and https pages. Every call runs on the
/// store's own serial queue.
public final class BrowserHistory: @unchecked Sendable {
  private let db: SQLiteDatabase
  private let queue = DispatchQueue(label: "dev.glance.browser-history")

  public init(url: URL) throws {
    db = try SQLiteDatabase(url: url, name: "browser history")
    try queue.sync {
      try db.exec("PRAGMA journal_mode = WAL")
      try db.exec("""
        CREATE TABLE IF NOT EXISTS visits (
          url TEXT PRIMARY KEY, bare TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', visits INTEGER NOT NULL,
          last REAL NOT NULL)
        """)
      try db.exec("CREATE INDEX IF NOT EXISTS visits_last ON visits(last)")
    }
  }

  /// A visit to `url`; a title given replaces the one kept, none keeps it.
  public func record(_ url: URL, title: String?, at date: Date) throws {
    guard Self.keeps(url) else { return }
    let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    try queue.sync {
      try db.run("""
        INSERT INTO visits(url, bare, title, visits, last) VALUES (?, ?, ?, 1, ?)
        ON CONFLICT(url) DO UPDATE SET visits = visits.visits + 1, last = excluded.last,
          title = CASE WHEN excluded.title = '' THEN visits.title ELSE excluded.title END
        """, [.text(url.absoluteString), .text(Self.bare(url)), .text(title), .real(date.timeIntervalSince1970)])
    }
  }

  /// The title a page showed once it loaded; no visit is counted.
  public func setTitle(_ title: String, for url: URL) throws {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard Self.keeps(url), !trimmed.isEmpty else { return }
    try queue.sync {
      try db.run("UPDATE visits SET title = ? WHERE url = ?", [.text(trimmed), .text(url.absoluteString)])
    }
  }

  /// Pages for the address field: an address starting with `text` (scheme and "www." ignored on both sides), or a
  /// title holding it; address matches first, then most visited, then most recent.
  public func matches(_ text: String, limit: Int) throws -> [HistoryEntry] {
    let needle = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !needle.isEmpty, limit > 0 else { return [] }
    let prefix = Self.escape(Self.bare(needle)) + "%"
    let contains = "%" + Self.escape(needle) + "%"
    return try select("""
      SELECT url, title, visits, last FROM visits
      WHERE bare LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\'
      ORDER BY (bare LIKE ? ESCAPE '\\') DESC, visits DESC, last DESC LIMIT ?
      """, [.text(prefix), .text(contains), .text(prefix), .int(limit)])
  }

  /// The most recently visited pages.
  public func recent(limit: Int) throws -> [HistoryEntry] {
    try select("SELECT url, title, visits, last FROM visits ORDER BY last DESC LIMIT ?", [.int(limit)])
  }

  public func clear() throws {
    try queue.sync { try db.run("DELETE FROM visits", []) }
  }

  private func select(_ sql: String, _ values: [SQLiteDatabase.Value]) throws -> [HistoryEntry] {
    try queue.sync {
      var entries: [HistoryEntry] = []
      try db.query(sql, values) { row in
        guard let text = row.text(0), let url = URL(string: text) else { return }
        entries.append(HistoryEntry(url: url, title: row.text(1) ?? "", visits: row.int(2) ?? 0,
                                    lastVisit: Date(timeIntervalSince1970: row.real(3) ?? 0)))
      }
      return entries
    }
  }

  static func keeps(_ url: URL) -> Bool {
    ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
  }

  /// "github.com/apple/swift" for "https://www.GitHub.com/apple/swift": lowercased, no scheme, no "www.".
  public static func bare(_ url: URL) -> String { bare(url.absoluteString) }

  static func bare(_ text: String) -> String {
    var text = text.lowercased()
    for scheme in ["https://", "http://"] where text.hasPrefix(scheme) { text.removeFirst(scheme.count) }
    if text.hasPrefix("www.") { text.removeFirst(4) }
    return text
  }

  /// `text` for a LIKE pattern with `\` as the escape: `%`, `_` and `\` match themselves.
  static func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_")
  }
}
