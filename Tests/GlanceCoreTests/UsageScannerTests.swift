import Foundation
import Testing
@testable import GlanceCore

private func usageLine(_ id: String, output: Int = 10) -> String {
  #"{"type":"assistant","sessionId":"s1","cwd":"/Users/me/app","timestamp":"2026-10-09T10:00:00Z","message":{"id":"\#(id)","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":\#(output)}}}"#
}

private func withProjects(_ body: (URL, UsageStore) throws -> Void) throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: root) }
  let projects = root.appendingPathComponent("projects")
  try FileManager.default.createDirectory(at: projects.appendingPathComponent("-Users-me-app/s1/subagents"),
                                          withIntermediateDirectories: true)
  try body(projects, try UsageStore(url: root.appendingPathComponent("usage.sqlite")))
}

private func write(_ text: String, to url: URL) throws { try Data(text.utf8).write(to: url) }

private func append(_ text: String, to url: URL) throws {
  let handle = try FileHandle(forWritingTo: url)
  try handle.seekToEnd()
  try handle.write(contentsOf: Data(text.utf8))
  try handle.close()
}

private func all(_ store: UsageStore) throws -> [String] {
  try store.records(from: .distantPast, to: .distantFuture).map(\.messageID)
}

@Test func transcriptsIncludeSubagentFilesAndNothingElse() throws {
  try withProjects { projects, _ in
    let folder = projects.appendingPathComponent("-Users-me-app")
    try write("", to: folder.appendingPathComponent("s1.jsonl"))
    try write("", to: folder.appendingPathComponent("s1/subagents/agent-a.jsonl"))
    try write("", to: folder.appendingPathComponent("notes.txt"))
    let names = UsageScanner.transcripts(in: projects).map(\.lastPathComponent).sorted()
    #expect(names == ["agent-a.jsonl", "s1.jsonl"])
  }
}

@Test func aSecondScanReadsOnlyNewLinesAndTheSameRequestCountsOnce() throws {
  try withProjects { projects, store in
    let folder = projects.appendingPathComponent("-Users-me-app")
    let main = folder.appendingPathComponent("s1.jsonl")
    try write(usageLine("a") + "\n" + usageLine("a") + "\n", to: main)
    try write(usageLine("a") + "\n" + usageLine("b") + "\n", to: folder.appendingPathComponent("s1/subagents/agent-a.jsonl"))
    #expect(try UsageScanner.scan(projects: projects, store: store, root: { $0 }) == 4)
    #expect(try all(store) == ["a", "b"])
    #expect(try UsageScanner.scan(projects: projects, store: store, root: { $0 }) == 0)
    try append(usageLine("c") + "\n", to: main)
    #expect(try UsageScanner.scan(projects: projects, store: store, root: { $0 }) == 1)
    #expect(try all(store) == ["a", "b", "c"])
  }
}

@Test func aHalfWrittenLineWaitsForTheNextScan() throws {
  try withProjects { projects, store in
    let main = projects.appendingPathComponent("-Users-me-app/s1.jsonl")
    let whole = usageLine("a")
    let cut = whole.index(whole.startIndex, offsetBy: 40)
    try write(String(whole[..<cut]), to: main)
    #expect(try UsageScanner.scan(projects: projects, store: store, root: { $0 }) == 0)
    #expect(try store.marks().values.first?.offset == 0)
    try append(String(whole[cut...]) + "\n", to: main)
    #expect(try UsageScanner.scan(projects: projects, store: store, root: { $0 }) == 1)
    #expect(try all(store) == ["a"])
  }
}

@Test func aShortenedOrReplacedFileIsReadAgainWithoutDoubleCounting() throws {
  try withProjects { projects, store in
    let main = projects.appendingPathComponent("-Users-me-app/s1.jsonl")
    try write(usageLine("a") + "\n" + usageLine("b") + "\n", to: main)
    try UsageScanner.scan(projects: projects, store: store, root: { $0 })
    try FileManager.default.removeItem(at: main)
    try write(usageLine("b") + "\n", to: main)
    try UsageScanner.scan(projects: projects, store: store, root: { $0 })
    #expect(try all(store) == ["a", "b"])
    #expect(try store.marks().values.first?.offset == usageLine("b").utf8.count + 1)
  }
}

@Test func aDeletedTranscriptKeepsItsRequests() throws {
  try withProjects { projects, store in
    let main = projects.appendingPathComponent("-Users-me-app/s1.jsonl")
    try write(usageLine("a") + "\n", to: main)
    try UsageScanner.scan(projects: projects, store: store, root: { $0 })
    try FileManager.default.removeItem(at: main)
    try UsageScanner.scan(projects: projects, store: store, root: { $0 })
    #expect(try all(store) == ["a"])
    #expect(try store.marks().isEmpty)
  }
}

@Test func progressCountsEveryFile() throws {
  try withProjects { projects, store in
    let folder = projects.appendingPathComponent("-Users-me-app")
    try write(usageLine("a") + "\n", to: folder.appendingPathComponent("s1.jsonl"))
    try write(usageLine("b") + "\n", to: folder.appendingPathComponent("s2.jsonl"))
    var seen: [UsageScanner.Progress] = []
    try UsageScanner.scan(projects: projects, store: store, root: { $0 }) { seen.append($0) }
    #expect(seen.last == UsageScanner.Progress(done: 2, total: 2))
    #expect(seen.count == 2)
  }
}

@Test func readLinesReportsEachLinesOffsetAcrossChunks() throws {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("lines-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: url) }
  let long = String(repeating: "x", count: 1_500_000)
  try write("ab\n" + long + "\ncd", to: url)
  var lines: [(String, Int)] = []
  let end = UsageScanner.readLines(url, from: 0) { lines.append(($0, $1)) }
  #expect(lines.map(\.0.count) == [2, 1_500_000])
  #expect(lines.map(\.1) == [0, 3])
  #expect(end == 3 + 1_500_000 + 1)
  #expect(UsageScanner.readLines(url.appendingPathExtension("missing"), from: 0) { _, _ in } == nil)
}
