import Foundation
import SQLite3

/// Why a SQLite call failed, in words.
public struct SQLiteFailure: Error, CustomStringConvertible, Sendable {
  public let description: String

  public init(description: String) {
    self.description = description
  }
}

/// One SQLite connection (opened read-write, created when missing, 2 s busy timeout) and the calls Glance's stores
/// need. Not thread-safe on its own: each store calls it from its own serial queue.
final class SQLiteDatabase {
  enum Value {
    case text(String?), real(Double?), int(Int?)
  }

  /// A result row, read by column index.
  struct Row {
    let statement: OpaquePointer

    func text(_ column: Int32) -> String? {
      guard sqlite3_column_type(statement, column) != SQLITE_NULL, let text = sqlite3_column_text(statement, column)
      else { return nil }
      return String(cString: text)
    }

    func real(_ column: Int32) -> Double? {
      sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_double(statement, column)
    }

    func int(_ column: Int32) -> Int? {
      sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, column))
    }

    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }

    func bool(_ column: Int32) -> Bool { sqlite3_column_int(statement, column) != 0 }
  }

  private let db: OpaquePointer
  /// The store's name in error messages ("history", "journal").
  let name: String

  init(url: URL, name: String) throws {
    self.name = name
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var handle: OpaquePointer?
    guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
      == SQLITE_OK, let handle else {
      let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
      sqlite3_close(handle)
      throw SQLiteFailure(description: "Couldn't open the \(name) at \(url.path): \(reason)")
    }
    db = handle
    sqlite3_busy_timeout(handle, 2000)
  }

  deinit { sqlite3_close(db) }

  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  func exec(_ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure("exec") }
  }

  func run(_ sql: String, _ values: [Value]) throws {
    try query(sql, values) { _ in }
  }

  /// Runs `sql` with `values` bound in order, calling `row` for each result row.
  func query(_ sql: String, _ values: [Value], row: (Row) throws -> Void) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure("prepare") }
    defer { sqlite3_finalize(statement) }
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      switch value {
      case .text(let text?): sqlite3_bind_text(statement, index, text, -1, Self.transient)
      case .real(let real?): sqlite3_bind_double(statement, index, real)
      case .int(let int?): sqlite3_bind_int64(statement, index, Int64(int))
      case .text(nil), .real(nil), .int(nil): sqlite3_bind_null(statement, index)
      }
    }
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW: try row(Row(statement: statement))
      case SQLITE_DONE: return
      default: throw failure("step")
      }
    }
  }

  /// `body` in one transaction: committed when it returns, rolled back when it throws.
  func transaction<T>(_ body: () throws -> T) throws -> T {
    try exec("BEGIN")
    do {
      let result = try body()
      try exec("COMMIT")
      return result
    } catch {
      try? exec("ROLLBACK")
      throw error
    }
  }

  private func failure(_ step: String) -> SQLiteFailure {
    SQLiteFailure(description: "\(name.prefix(1).uppercased() + name.dropFirst()) \(step) failed: "
      + String(cString: sqlite3_errmsg(db)))
  }
}
