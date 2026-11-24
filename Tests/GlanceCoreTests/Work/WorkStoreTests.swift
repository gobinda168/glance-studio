import Foundation
import Testing
@testable import GlanceCore

@Suite struct WorkStoreTests {
  func scratch() -> WorkStore {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("work-\(UUID().uuidString)")
    return WorkStore(folder: url)
  }

  func run(_ name: String, env: String? = nil, exit: Int = 0, at: Date, id: String = UUID().uuidString) -> ProofCheckRun {
    ProofCheckRun(id: id, name: name, environment: env, command: name, exitCode: exit, outputTail: "", at: at)
  }

  @Test func updateCreatesAndReadsBack() {
    let store = scratch()
    let at = Date(timeIntervalSince1970: 1_000)
    store.update(session: "s1", now: at) { $0.notes.append(ProofNote(kind: .found, text: "Cache key ignores locale", at: at)) }
    let record = store.record(session: "s1")
    #expect(record?.notes.map(\.text) == ["Cache key ignores locale"])
    #expect(record?.updated == at)
  }

  @Test func theStampMovesWhenTheRecordOrTheSummaryIsWritten() throws {
    let store = scratch()
    let summaries = store.folder.appendingPathComponent("summaries")
    #expect(store.stamp(session: "s1", summaries: summaries) == RecordFreshness.none)
    let first = Date(timeIntervalSince1970: 1_000), second = Date(timeIntervalSince1970: 2_000)
    store.update(session: "s1", now: first) { $0.pending.append(ProofPending(text: "x", at: first)) }
    try FileManager.default.setAttributes([.modificationDate: first], ofItemAtPath: store.sessionFolder("s1").appendingPathComponent("record.json").path)
    #expect(store.stamp(session: "s1", summaries: summaries) == first)
    try FileManager.default.createDirectory(at: summaries, withIntermediateDirectories: true)
    let summary = summaries.appendingPathComponent("s1.json")
    try Data(#"{"title":"t"}"#.utf8).write(to: summary)
    try FileManager.default.setAttributes([.modificationDate: second], ofItemAtPath: summary.path)
    #expect(store.stamp(session: "s1", summaries: summaries) == second)
    #expect(store.stamp(session: "../x", summaries: summaries) == RecordFreshness.none)
  }

  @Test func concurrentUpdatesKeepBoth() {
    let store = scratch()
    DispatchQueue.concurrentPerform(iterations: 20) { i in
      store.update(session: "s1", budget: 5) { $0.pending.append(ProofPending(text: "item \(i)", at: Date())) }
    }
    #expect(store.record(session: "s1")?.pending.count == 20)
  }

  @Test func theCacheFolderSitsInTheSessionFolderApartFromMedia() {
    let store = scratch()
    #expect(store.cacheFolder(session: "s1") == store.sessionFolder("s1").appendingPathComponent("cache", isDirectory: true))
    #expect(store.cacheFolder(session: "s1") != store.mediaFolder(session: "s1"))
  }

  @Test func rejectsUnsafeSessionIDs() {
    #expect(WorkStore.isSessionID("3a1c373e-9f2b-4c1d-8e7f-000000000000"))
    #expect(!WorkStore.isSessionID("../etc"))
    #expect(!WorkStore.isSessionID(""))
    let store = scratch()
    #expect(store.update(session: "../x") { _ in } == nil)
  }

  @Test func decodesOldRecordWithMissingArrays() throws {
    let json = #"{"session":"s1","updated":"2026-11-01T10:00:00Z"}"#
    let record = try WorkRecord.decoder.decode(WorkRecord.self, from: Data(json.utf8))
    #expect(record.checks.isEmpty && record.captures.isEmpty && record.verdict == nil)
  }

  @Test func pruneRemovesRecordsOlderThanSixtyDays() {
    let store = scratch()
    let now = Date(timeIntervalSince1970: 100 * 86_400)
    store.update(session: "old", now: now.addingTimeInterval(-61 * 86_400)) { _ in }
    store.update(session: "new", now: now.addingTimeInterval(-59 * 86_400)) { _ in }
    store.prune(now: now, force: true)
    #expect(store.record(session: "old") == nil)
    #expect(store.record(session: "new") != nil)
  }

  @Test func recordsListsEverySession() {
    let store = scratch()
    store.update(session: "a") { $0.branch = "feat/a" }
    store.update(session: "b") { $0.branch = "feat/b" }
    #expect(Set(store.records().compactMap(\.branch)) == ["feat/a", "feat/b"])
  }

  // Two runs in one second must keep their order on disk: dates are written with fractions, and both the pre-fraction
  // and the fractional spelling decode.
  @Test func datesKeepFractionalSeconds() throws {
    let store = scratch()
    let first = Date(timeIntervalSince1970: 1_000.250)
    let second = Date(timeIntervalSince1970: 1_000.750)
    store.update(session: "s1", now: second) {
      $0.checks = [run("tests", exit: 1, at: first, id: "a"), run("tests", exit: 0, at: second, id: "b")]
    }
    let back = try #require(store.record(session: "s1")).checks
    #expect(back.map(\.id) == ["a", "b"])
    #expect(back[0].at < back[1].at)
    #expect(abs(back[0].at.timeIntervalSince1970 - 1_000.250) < 0.001)

    let whole = #"{"session":"s1","updated":"2026-11-01T10:00:00Z"}"#
    let fractional = #"{"session":"s1","updated":"2026-11-01T10:00:00.500Z"}"#
    let a = try WorkRecord.decoder.decode(WorkRecord.self, from: Data(whole.utf8)).updated
    let b = try WorkRecord.decoder.decode(WorkRecord.self, from: Data(fractional.utf8)).updated
    #expect(b.timeIntervalSince(a) == 0.5)
  }

  @Test func keepsTheLatestTwentyRunsPerCheckAndEnvironment() throws {
    let store = scratch()
    let base = Date(timeIntervalSince1970: 5_000)
    store.update(session: "s1", now: base) { record in
      for i in 0..<25 { record.checks.append(run("tests", env: "ci", at: base.addingTimeInterval(Double(i)), id: "t\(i)")) }
      for i in 0..<3 { record.checks.append(run("tests", env: nil, at: base.addingTimeInterval(Double(i)), id: "n\(i)")) }
      for i in 0..<2 { record.checks.append(run("lint", env: "ci", at: base.addingTimeInterval(Double(i)), id: "l\(i)")) }
    }
    let checks = try #require(store.record(session: "s1")).checks
    let ci = checks.filter { $0.name == "tests" && $0.environment == "ci" }
    #expect(ci.count == WorkRecord.runsKept)
    #expect(ci.first?.id == "t5" && ci.last?.id == "t24")
    #expect(checks.filter { $0.name == "tests" && $0.environment == nil }.count == 3)
    #expect(checks.filter { $0.name == "lint" }.count == 2)
    #expect(checks.count == 25)
  }

  // The daily prune runs inside a hook: it must judge by the folder's modification time and never decode a record.
  @Test func pruneJudgesByFolderTimeWithoutDecoding() throws {
    let store = scratch()
    let fm = FileManager.default
    let now = Date(timeIntervalSince1970: 200 * 86_400)
    func plant(_ session: String, age days: Double) throws {
      let dir = store.sessionFolder(session)
      try fm.createDirectory(at: dir, withIntermediateDirectories: true)
      try Data("not json at all".utf8).write(to: dir.appendingPathComponent("record.json"))
      try fm.setAttributes([.modificationDate: now.addingTimeInterval(-days * 86_400)], ofItemAtPath: dir.path)
    }
    try plant("stale", age: 61)
    try plant("fresh", age: 59)
    store.prune(now: now, force: true)
    #expect(!fm.fileExists(atPath: store.sessionFolder("stale").path))
    #expect(fm.fileExists(atPath: store.sessionFolder("fresh").path))
  }

  @Test func pruneRunsAtMostOncePerDay() throws {
    let store = scratch()
    let fm = FileManager.default
    let now = Date(timeIntervalSince1970: 300 * 86_400)
    store.update(session: "live", now: now) { _ in }
    let stale = store.sessionFolder("stale")
    try fm.createDirectory(at: stale, withIntermediateDirectories: true)
    try fm.setAttributes([.modificationDate: now.addingTimeInterval(-90 * 86_400)], ofItemAtPath: stale.path)
    store.prune(now: now)  // the update above already stamped today
    #expect(fm.fileExists(atPath: stale.path))
    store.prune(now: now.addingTimeInterval(86_400 + 1))
    #expect(!fm.fileExists(atPath: stale.path))
  }

  // MARK: Media housekeeping (Settings: the folder's size, Clear old media)

  /// A session with `media/clip.mp4` and `cache/pr/a.png` of the given sizes and a record, its folder last changed
  /// `age` days before `now`.
  @discardableResult
  func plantSession(_ store: WorkStore, _ id: String, media: Int = 1_000, cache: Int = 500, age: Double, now: Date) throws -> URL {
    let fm = FileManager.default
    store.update(session: id, now: now) { $0.notes.append(ProofNote(kind: .found, text: "kept", at: now)) }
    try fm.createDirectory(at: store.mediaFolder(session: id), withIntermediateDirectories: true)
    try fm.createDirectory(at: store.cacheFolder(session: id).appendingPathComponent("pr"), withIntermediateDirectories: true)
    try Data(count: media).write(to: store.mediaFolder(session: id).appendingPathComponent("clip.mp4"))
    try Data(count: cache).write(to: store.cacheFolder(session: id).appendingPathComponent("pr/a.png"))
    let dir = store.sessionFolder(id)
    try fm.setAttributes([.modificationDate: now.addingTimeInterval(-age * 86_400)], ofItemAtPath: dir.path)
    return dir
  }

  @Test func mediaSizeCountsMediaCacheAndHalfWrittenClips() throws {
    let store = scratch()
    let now = Date(timeIntervalSince1970: 400 * 86_400)
    try plantSession(store, "one", media: 1_000, cache: 500, age: 1, now: now)
    try plantSession(store, "two", media: 2_000, cache: 0, age: 30, now: now)
    let tmp = store.folder.appendingPathComponent(".tmp-clips", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    try Data(count: 4_000).write(to: tmp.appendingPathComponent("123-abc.mp4"))
    #expect(store.mediaSize() == 1_000 + 500 + 2_000 + 4_000)
  }

  @Test func mediaSizeOfAMissingFolderIsZero() {
    #expect(scratch().mediaSize() == 0)
  }

  @Test func clearingOldMediaKeepsTheRecordAndSparesRecentAndLiveSessions() throws {
    let store = scratch()
    let fm = FileManager.default
    let now = Date(timeIntervalSince1970: 400 * 86_400)
    let old = try plantSession(store, "old", media: 1_000, cache: 500, age: 20, now: now)
    let recent = try plantSession(store, "recent", media: 1_000, cache: 500, age: 3, now: now)
    let live = try plantSession(store, "live", media: 1_000, cache: 500, age: 90, now: now)
    let freed = store.clearOldMedia(olderThan: 14, liveSessions: ["live"], now: now)
    #expect(freed == 1_500)
    #expect(!fm.fileExists(atPath: store.mediaFolder(session: "old").path))
    #expect(!fm.fileExists(atPath: store.cacheFolder(session: "old").path))
    #expect(fm.fileExists(atPath: old.appendingPathComponent("record.json").path))
    #expect(store.record(session: "old")?.notes.map(\.text) == ["kept"], "the record stays")
    #expect(fm.fileExists(atPath: store.mediaFolder(session: "recent").appendingPathComponent("clip.mp4").path))
    #expect(fm.fileExists(atPath: recent.appendingPathComponent("record.json").path))
    #expect(fm.fileExists(atPath: store.mediaFolder(session: "live").appendingPathComponent("clip.mp4").path))
    #expect(fm.fileExists(atPath: store.cacheFolder(session: "live").appendingPathComponent("pr/a.png").path))
    #expect(fm.fileExists(atPath: live.appendingPathComponent("record.json").path))
    #expect(store.mediaSize() == 3_000)
  }

  @Test func clearingOldMediaLeavesTheFolderTimeAlone() throws {
    let store = scratch()
    let now = Date(timeIntervalSince1970: 400 * 86_400)
    let dir = try plantSession(store, "old", age: 20, now: now)
    let before = try dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    store.clearOldMedia(olderThan: 14, liveSessions: [], now: now)
    let after = try dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    #expect(before == after, "ageing is by the record's last change, so clearing twice frees nothing the second time")
    #expect(store.clearOldMedia(olderThan: 14, liveSessions: [], now: now) == 0)
  }

  @Test func clearingOldMediaIgnoresFoldersThatAreNotSessions() throws {
    let store = scratch()
    let fm = FileManager.default
    let now = Date(timeIntervalSince1970: 400 * 86_400)
    let tmp = store.folder.appendingPathComponent(".tmp-clips", isDirectory: true)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    try Data(count: 100).write(to: tmp.appendingPathComponent("1-x.mp4"))
    try fm.setAttributes([.modificationDate: now.addingTimeInterval(-90 * 86_400)], ofItemAtPath: tmp.path)
    #expect(store.clearOldMedia(olderThan: 14, liveSessions: [], now: now) == 0)
    #expect(fm.fileExists(atPath: tmp.appendingPathComponent("1-x.mp4").path))
  }

  @Test func liveSessionsAreTheLedgersWhoseClaudeIsStillRunning() throws {
    let ledger = Ledger(folder: FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString)"))
    let at = Date(timeIntervalSince1970: 400 * 86_400)
    var state = TrackState(repo: "/repo/.git")
    state.sessions["running"] = TrackedSession(id: "running", worktree: "/repo", branch: nil, pid: 111, terminal: nil,
                                               task: nil, started: at, ended: nil)
    state.sessions["dead"] = TrackedSession(id: "dead", worktree: "/repo", branch: nil, pid: 222, terminal: nil,
                                            task: nil, started: at, ended: nil)
    state.sessions["ended"] = TrackedSession(id: "ended", worktree: "/repo", branch: nil, pid: 111, terminal: nil,
                                             task: nil, started: at, ended: at)
    ledger.save(state)
    #expect(WorkStore.liveSessions(ledger: ledger, alive: { $0 == 111 }) == ["running"])
    #expect(WorkStore.liveSessions(ledger: Ledger(folder: ledger.folder.appendingPathComponent("none")), alive: { _ in true }).isEmpty)
  }
}
