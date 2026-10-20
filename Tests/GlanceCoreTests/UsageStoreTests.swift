import Foundation
import Testing
@testable import GlanceCore

private func withStore(_ body: (UsageStore, URL) throws -> Void) throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: folder) }
  let url = folder.appendingPathComponent("usage.sqlite")
  try body(try UsageStore(url: url), url)
}

private func request(_ id: String, at seconds: Double, output: Int = 10) -> UsageRecord {
  UsageRecord(messageID: id, time: Date(timeIntervalSince1970: seconds), model: "claude-opus-5-5", sessionID: "s",
              project: "/p", subagent: id.hasPrefix("sub"), fast: false, input: 1, output: output,
              cacheWrite5m: 2, cacheWrite1h: 3, cacheRead: 4)
}

private let mark = UsageStore.FileMark(offset: 100, inode: 7, size: 120)

@Test func aRequestIsKeptOnceWhateverHowOftenItIsSaved() throws {
  try withStore { store, _ in
    try store.save([request("a", at: 1000), request("a", at: 1000, output: 99)], path: "/t/a.jsonl", mark: mark)
    try store.save([request("a", at: 1000, output: 77), request("b", at: 2000)], path: "/t/b.jsonl", mark: mark)
    let rows = try store.records(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 5000))
    #expect(rows.map(\.messageID) == ["a", "b"])
    #expect(rows.first == request("a", at: 1000))
  }
}

@Test func rangesIncludeTheStartAndExcludeTheEnd() throws {
  try withStore { store, _ in
    try store.save([request("a", at: 1000), request("b", at: 2000), request("c", at: 3000)], path: "/t", mark: mark)
    let rows = try store.records(from: Date(timeIntervalSince1970: 1000), to: Date(timeIntervalSince1970: 3000))
    #expect(rows.map(\.messageID) == ["a", "b"])
    #expect(try store.earliest() == Date(timeIntervalSince1970: 1000))
  }
}

@Test func marksAreSavedWithTheirRowsAndForgottenWithoutLosingRows() throws {
  try withStore { store, _ in
    #expect(try store.earliest() == nil)
    try store.save([request("a", at: 1000)], path: "/t/a.jsonl", mark: mark)
    try store.save([], path: "/t/b.jsonl", mark: UsageStore.FileMark(offset: 5, inode: 8, size: 5))
    #expect(try store.marks() == ["/t/a.jsonl": mark, "/t/b.jsonl": UsageStore.FileMark(offset: 5, inode: 8, size: 5)])
    try store.keepMarks(only: ["/t/b.jsonl"])
    #expect(try store.marks().keys.sorted() == ["/t/b.jsonl"])
    #expect(try store.records(from: .distantPast, to: .distantFuture).count == 1)
  }
}

@Test func theStoreSurvivesReopening() throws {
  try withStore { store, url in
    try store.save([request("a", at: 1000)], path: "/t/a.jsonl", mark: mark)
    let again = try UsageStore(url: url)
    #expect(try again.records(from: .distantPast, to: .distantFuture).map(\.messageID) == ["a"])
    #expect(try again.marks()["/t/a.jsonl"] == mark)
  }
}

@Test func aDamagedFileIsMovedAsideAndANewerOneRefused() throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: folder) }
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let url = folder.appendingPathComponent("usage.sqlite")
  try Data(repeating: 0x41, count: 4096).write(to: url)
  let opened = try UsageStore.open(url: url, now: Date(timeIntervalSince1970: 1234))
  #expect(opened.movedAside?.lastPathComponent == "usage-damaged-1234.sqlite")
  #expect(try opened.store.earliest() == nil)

  let newer = folder.appendingPathComponent("newer.sqlite")
  _ = try UsageStore(url: newer)
  let db = try SQLiteDatabase(url: newer, name: "usage")
  try db.run("UPDATE meta SET value = '99' WHERE key = 'schema'", [])
  #expect(throws: UsageStore.NewerSchema.self) { _ = try UsageStore.open(url: newer) }
}
