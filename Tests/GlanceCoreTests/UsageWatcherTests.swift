import Foundation
import Testing
@testable import GlanceCore

/// The five-hour percentage of each report, in order; -1 for "nothing to show".
private final class Reports: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Int] = []

  func add(_ reading: UsageWatcher.Reading?) {
    lock.lock()
    values.append(reading?.usage.fiveHour?.shownPercent ?? -1)
    lock.unlock()
  }

  var all: [Int] { lock.lock(); defer { lock.unlock() }; return values }
  var latest: Int? { all.last }
}

private func makeDirectory() throws -> URL {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usage-watcher-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir
}

/// A status-line payload whose five-hour window resets two hours from now (the watcher judges against the real clock).
private func write(percent: Int, to file: URL) throws {
  let reset = Int(Date().timeIntervalSince1970) + 7200
  let json = #"{"rate_limits":{"five_hour":{"used_percentage":\#(percent),"resets_at":\#(reset)}}}"#
  try Data(json.utf8).write(to: file, options: .atomic) // a rename, like the script's mv
}

private func eventually(_ timeout: Double = 3, _ condition: () -> Bool) async -> Bool {
  let end = Date().addingTimeInterval(timeout)
  while Date() < end {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(20))
  }
  return condition()
}

/// A watcher on a private queue. `tick` stays long so only the file-system events and the retry can find a change.
private func makeWatcher(_ file: URL, reports: Reports) -> UsageWatcher {
  let watcher = UsageWatcher(file: file, queue: DispatchQueue(label: "usage-watcher-test"), tick: 60, retry: 0.1)
  watcher.onChange = { reports.add($0) }
  return watcher
}

@Test func anExistingFileIsReportedAtStart() async throws {
  let dir = try makeDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let file = dir.appendingPathComponent("usage.json")
  try write(percent: 23, to: file)
  let reports = Reports()
  let watcher = makeWatcher(file, reports: reports)
  watcher.start()
  defer { watcher.stop() }
  #expect(await eventually { reports.latest == 23 })
}

@Test func aReplacedFileIsSeen() async throws {
  let dir = try makeDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let file = dir.appendingPathComponent("usage.json")
  try write(percent: 20, to: file)
  let reports = Reports()
  let watcher = makeWatcher(file, reports: reports)
  watcher.start()
  defer { watcher.stop() }
  #expect(await eventually { reports.latest == 20 })
  try write(percent: 30, to: file)
  #expect(await eventually { reports.latest == 30 })
}

@Test func aDeletedFileHidesTheStrip() async throws {
  let dir = try makeDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let file = dir.appendingPathComponent("usage.json")
  try write(percent: 20, to: file)
  let reports = Reports()
  let watcher = makeWatcher(file, reports: reports)
  watcher.start()
  defer { watcher.stop() }
  #expect(await eventually { reports.latest == 20 })
  try FileManager.default.removeItem(at: file)
  #expect(await eventually { reports.latest == -1 })
}

@Test func aDirectoryThatAppearsLaterIsPickedUp() async throws {
  let parent = try makeDirectory()
  defer { try? FileManager.default.removeItem(at: parent) }
  let dir = parent.appendingPathComponent("glance") // Glance setup hasn't run yet
  let file = dir.appendingPathComponent("usage.json")
  let reports = Reports()
  let watcher = makeWatcher(file, reports: reports)
  watcher.start()
  defer { watcher.stop() }
  #expect(await eventually { reports.latest == -1 })
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  try write(percent: 41, to: file)
  #expect(await eventually { reports.latest == 41 })
}

@Test func aRecreatedDirectoryIsWatchedAgain() async throws {
  let parent = try makeDirectory()
  defer { try? FileManager.default.removeItem(at: parent) }
  let dir = parent.appendingPathComponent("glance")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let file = dir.appendingPathComponent("usage.json")
  try write(percent: 20, to: file)
  let reports = Reports()
  let watcher = makeWatcher(file, reports: reports)
  watcher.start()
  defer { watcher.stop() }
  #expect(await eventually { reports.latest == 20 })

  try FileManager.default.removeItem(at: dir) // unsetup…
  #expect(await eventually { reports.latest == -1 })
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) // …then setup again
  try write(percent: 55, to: file)
  #expect(await eventually { reports.latest == 55 })
}

@Test func anIdleSessionsOlderSnapshotDoesNotRollTheNumbersBack() async throws {
  let dir = try makeDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let file = dir.appendingPathComponent("usage.json")
  try write(percent: 40, to: file)
  let reports = Reports()
  let watcher = makeWatcher(file, reports: reports)
  watcher.start()
  defer { watcher.stop() }
  #expect(await eventually { reports.latest == 40 })
  let seen = reports.all.count
  try write(percent: 30, to: file)
  #expect(await eventually { reports.all.count > seen })
  #expect(reports.latest == 40)
}
