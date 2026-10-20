import Foundation
import Testing
@testable import GlanceCore

private let day = JournalDay(key: "2026-10-09")!
private let nextDay = JournalDay(key: "2026-10-10")!
private func time(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

private func withStore(_ body: (JournalStore, URL) throws -> Void) throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: folder) }
  let url = folder.appendingPathComponent("journal.sqlite")
  try body(try JournalStore(url: url), url)
}

private func commit(_ id: String, on day: JournalDay = day, title: String = "fix", at seconds: Double = 1000) -> JournalEvent {
  JournalEvent(source: .git, externalID: id, day: day, start: time(seconds), project: "/p", title: title,
               detail: JournalDetail(hash: id, insertions: 3))
}

@Test func eventsAreUpsertedNotDuplicated() throws {
  try withStore { store, _ in
    try store.upsert([commit("a", title: "first")], now: time(100))
    try store.upsert([commit("a", title: "second")], now: time(200))
    let events = try store.events(on: day)
    #expect(events.count == 1)
    #expect(events.first?.title == "second")
    #expect(events.first?.detail.insertions == 3)
    #expect(try store.summaries().map(\.day) == [day])
    #expect(try store.summaries().first?.status == .open)
    #expect(try store.summaries().first?.eventCount == 1)
  }
}

@Test func recordsAndEntriesRoundTrip() throws {
  try withStore { store, _ in
    let span = JournalSpan(start: time(1000), end: time(1600))
    let record = JournalDayRecord(day: day, status: .drafted, headline: "Shipped", recap: "Para one.\n\nPara two.",
                                  minutesByProject: ["/p": 40], generatedAt: time(2000), error: nil,
                                  sourceNotes: ["GitHub": "signed out"], terminal: ["/p": [span]])
    try store.save(record)
    #expect(try store.record(day) == record)
    let entry = JournalEntry(id: "e1", day: day, position: 0, title: "Faster startup", summary: "Cut it.",
                             project: "/p", kind: .fixed, impact: "292 s → 40 s", challenge: "c", approach: "a",
                             outcome: "o", lesson: "l", skills: ["performance"], minutes: 90, highlight: true,
                             publicDraft: "p", eventIDs: ["git:a"], edited: true, createdAt: time(3000))
    try store.save(entry)
    #expect(try store.entries(on: day) == [entry])
    try store.deleteEntry(id: "e1")
    #expect(try store.entries(on: day).isEmpty)
  }
}

@Test func replacingEntriesSwapsTheDraft() throws {
  try withStore { store, _ in
    let old = JournalEntry(id: "old", day: day, title: "Old", createdAt: time(1))
    let kept = JournalEntry(id: "kept", day: day, title: "Kept", edited: true, createdAt: time(1))
    try store.save(old)
    try store.save(kept)
    let fresh = JournalEntry(id: "new", day: day, position: 1, title: "New", createdAt: time(2))
    let record = JournalDayRecord(day: day, status: .drafted, headline: "H", recap: "R", generatedAt: time(2))
    try store.replaceEntries(on: day, with: [kept, fresh], record: record)
    #expect(try store.entries(on: day).map(\.id) == ["kept", "new"])
    #expect(try store.record(day)?.headline == "H")
  }
}

@Test func newSinceRecapCountsEventsFirstCollectedAfterTheRecap() throws {
  try withStore { store, _ in
    try store.upsert([commit("a")], now: time(100))
    try store.save(JournalDayRecord(day: day, status: .drafted, headline: "H", recap: "R", generatedAt: time(150)))
    try store.upsert([commit("b")], now: time(200))
    try store.upsert([commit("a", title: "renamed")], now: time(300))
    #expect(try store.summaries().first?.newSinceRecap == 1)
  }
}

@Test func deletingADayRemovesOnlyThatDay() throws {
  try withStore { store, _ in
    try store.upsert([commit("a"), commit("b", on: nextDay, at: 90_000)])
    try store.save(JournalEntry(id: "e", day: day, title: "E", createdAt: time(1)))
    try store.deleteDay(day)
    #expect(try store.events(on: day).isEmpty)
    #expect(try store.entries(on: day).isEmpty)
    #expect(try store.record(day) == nil)
    #expect(try store.events(on: nextDay).count == 1)
  }
}

@Test func deletingEverythingEmptiesTheJournalButKeepsItUsable() throws {
  try withStore { store, url in
    try store.upsert([commit("a")])
    try store.save(JournalEntry(id: "e", day: day, title: "E", createdAt: time(1)))
    try store.setMeta("last_collected_day", "2026-10-09")
    try store.deleteAll()
    #expect(try store.summaries().isEmpty)
    #expect(try store.entries(from: day, through: nextDay).isEmpty)
    #expect(try store.meta("last_collected_day") == nil)
    #expect(try store.meta("schema") == "1")
    let again = try JournalStore(url: url)
    #expect(try again.summaries().isEmpty)
  }
}

@Test func daysAreFoundByTheirRecapsAndEntries() throws {
  try withStore { store, _ in
    try store.save(JournalDayRecord(day: day, status: .drafted, headline: "Shipped the store", recap: "Fast now."))
    try store.save(JournalDayRecord(day: nextDay, status: .drafted, headline: "Quiet day", recap: "Reviews."))
    try store.save(JournalEntry(id: "g", day: nextDay, title: "Gunicorn fix", summary: "Cut startup by 80%",
                                createdAt: time(1)))
    #expect(try store.days(matching: "gunicorn") == [nextDay])
    #expect(try store.days(matching: "STORE") == [day])
    #expect(try store.days(matching: "80%") == [nextDay])
    #expect(try store.days(matching: "_") == [])
    #expect(try store.days(matching: "e") == [nextDay, day])
  }
}

@Test func aNoteIsDeletedByItsID() throws {
  try withStore { store, _ in
    let note = JournalEvent(source: .note, externalID: "n1", day: day, start: time(5), title: "customer call")
    try store.upsert([note])
    try store.deleteEvent(id: note.id)
    #expect(try store.events(on: day).isEmpty)
  }
}

@Test func aDamagedFileIsMovedAsideAndAFreshJournalStarts() throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: folder) }
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let url = folder.appendingPathComponent("journal.sqlite")
  try Data(repeating: 0x41, count: 4096).write(to: url)
  let (store, aside) = try JournalStore.open(url: url, now: time(1_760_000_000))
  #expect(aside?.lastPathComponent == "journal-damaged-1760000000.sqlite")
  #expect(try Data(contentsOf: aside!) == Data(repeating: 0x41, count: 4096))
  try store.upsert([commit("a")])
  #expect(try store.events(on: day).count == 1)
}

@Test func aNewerJournalIsLeftAlone() throws {
  try withStore { store, url in
    try store.setMeta("schema", "2")
    #expect(throws: JournalStore.NewerSchema.self) { _ = try JournalStore.open(url: url) }
    #expect(FileManager.default.fileExists(atPath: url.path))
    let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
    #expect(!names.contains { $0.hasPrefix("journal-damaged") })
  }
}
