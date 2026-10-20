import Foundation
import Testing
@testable import GlanceCore

@Test func recordsOrdinaryCommandsOnly() {
  #expect(HistoryPolicy.shouldRecord("git status"))
  #expect(!HistoryPolicy.shouldRecord(" git status"))
  #expect(!HistoryPolicy.shouldRecord(""))
  #expect(!HistoryPolicy.shouldRecord("   \n"))
  #expect(!HistoryPolicy.shouldRecord("export API_TOKEN=abc123"))
}

@Test func storeCreatesInsertsAndReopens() throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: folder) }
  let url = folder.appendingPathComponent("nested/history.sqlite")
  do {
    let store = try CommandHistoryStore(url: url)
    #expect(try store.count() == 0)
    try store.insert(CommandRecord(command: "git status", folder: "/p", start: Date(timeIntervalSince1970: 100),
                                   duration: 0.25, exitCode: 0, tab: "T1", gitRoot: "/p", branch: "main", imported: false))
    try store.insert(CommandRecord(command: "make\nall", folder: nil, start: Date(timeIntervalSince1970: 50),
                                   duration: nil, exitCode: nil, tab: nil, gitRoot: nil, branch: nil, imported: true))
    #expect(try store.count() == 2)
  }
  let again = try CommandHistoryStore(url: url)
  #expect(try again.count() == 2)
  #expect(FileManager.default.fileExists(atPath: url.path))
}

private func tempStore() throws -> (CommandHistoryStore, URL) {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString)")
  return (try CommandHistoryStore(url: folder.appendingPathComponent("history.sqlite")), folder)
}

private func run(_ command: String, at seconds: Double, folder: String? = "/p", exit: Int? = 0, tab: String? = "T1",
                 imported: Bool = false) -> CommandRecord {
  CommandRecord(command: command, folder: folder, start: Date(timeIntervalSince1970: seconds), duration: imported ? nil : 0.5,
                exitCode: exit, tab: tab, gitRoot: folder, branch: folder == nil ? nil : "main", imported: imported)
}

@Test func storeRoundTripsEveryField() throws {
  let (store, folder) = try tempStore()
  defer { try? FileManager.default.removeItem(at: folder) }
  let records = [run("git status", at: 200), run("make\nall", at: 100, folder: nil, exit: nil, tab: nil, imported: true)]
  try store.insert(records)
  #expect(try store.all() == records.reversed()) // oldest first
}

@Test func deletingRemovesEveryRunOfOneCommand() throws {
  let (store, folder) = try tempStore()
  defer { try? FileManager.default.removeItem(at: folder) }
  try store.insert([run("ls", at: 1), run("git push", at: 2), run("ls", at: 3), run("ls -la", at: 4)])
  try store.delete(command: "ls")
  #expect(try store.all().map(\.command) == ["git push", "ls -la"])
  try store.deleteAll()
  #expect(try store.count() == 0)
}

@Test func reimportReplacesTheImportedRows() throws {
  let (store, folder) = try tempStore()
  defer { try? FileManager.default.removeItem(at: folder) }
  try store.insert([run("old", at: 1, folder: nil, imported: true), run("kept", at: 5)])
  try store.deleteImported()
  try store.insert([run("old", at: 1, folder: nil, imported: true)])
  #expect(try store.all().map(\.command) == ["old", "kept"])
  #expect(try store.meta("zshHistoryImported") == nil)
  try store.setMeta("zshHistoryImported", "/Users/u/.zsh_history")
  #expect(try store.meta("zshHistoryImported") == "/Users/u/.zsh_history")
}

@Test func recordsBetweenTwoTimesComeBackOldestFirst() throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: folder) }
  let store = try CommandHistoryStore(url: folder.appendingPathComponent("history.sqlite"))
  for (command, start) in [("late", 300.0), ("early", 100.0), ("outside", 50.0), ("edge", 400.0)] {
    try store.insert(CommandRecord(command: command, folder: "/p", start: Date(timeIntervalSince1970: start),
                                   duration: 1, exitCode: 0, tab: nil, gitRoot: "/p", branch: nil, imported: false))
  }
  let found = try store.records(from: Date(timeIntervalSince1970: 100), to: Date(timeIntervalSince1970: 400))
  #expect(found.map(\.command) == ["early", "late"])
}
