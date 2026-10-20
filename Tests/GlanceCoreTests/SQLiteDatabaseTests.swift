import Foundation
import Testing
@testable import GlanceCore

private func scratchURL(_ name: String) -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent("sqlite-\(UUID().uuidString)").appendingPathComponent(name)
}

@Test func aDatabaseRunsQueriesAndReadsTypedRows() throws {
  let url = scratchURL("test.sqlite")
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let db = try SQLiteDatabase(url: url, name: "test")
  try db.exec("CREATE TABLE t (name TEXT, size REAL, count INTEGER, flag INTEGER)")
  try db.run("INSERT INTO t VALUES (?, ?, ?, ?)", [.text("a"), .real(1.5), .int(3), .int(1)])
  try db.run("INSERT INTO t VALUES (?, ?, ?, ?)", [.text(nil), .real(nil), .int(nil), .int(0)])
  var rows: [String] = []
  try db.query("SELECT name, size, count, flag FROM t ORDER BY rowid", []) { row in
    rows.append([row.text(0) ?? "-", row.real(1).map { "\($0)" } ?? "-", row.int(2).map { "\($0)" } ?? "-",
                 "\(row.bool(3))"].joined(separator: " "))
  }
  #expect(rows == ["a 1.5 3 true", "- - - false"])
}

@Test func aTransactionThatThrowsLeavesNothingBehind() throws {
  let url = scratchURL("test.sqlite")
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let db = try SQLiteDatabase(url: url, name: "test")
  try db.exec("CREATE TABLE t (n INTEGER)")
  struct Stop: Error {}
  do {
    try db.transaction {
      try db.run("INSERT INTO t VALUES (?)", [.int(1)])
      throw Stop()
    }
    Issue.record("The transaction should have thrown")
  } catch is Stop {}
  var count = -1
  try db.query("SELECT COUNT(*) FROM t", []) { count = $0.int(0) ?? -1 }
  #expect(count == 0)
  let kept: Int = try db.transaction {
    try db.run("INSERT INTO t VALUES (?)", [.int(2)])
    return 2
  }
  try db.query("SELECT COUNT(*) FROM t", []) { count = $0.int(0) ?? -1 }
  #expect(kept == 2 && count == 1)
}

@Test func aFailureNamesTheStoreAndTheStep() throws {
  let url = scratchURL("test.sqlite")
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let db = try SQLiteDatabase(url: url, name: "test")
  do {
    try db.exec("NOT SQL")
    Issue.record("exec should have thrown")
  } catch let failure as SQLiteFailure {
    #expect(failure.description.hasPrefix("Test exec failed:"))
  }
}
