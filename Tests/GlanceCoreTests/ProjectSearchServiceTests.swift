import Foundation
import Testing
@testable import GlanceCore

private func makeRoot(_ files: [String: String]) throws -> String {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glance-search-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  for (path, content) in files {
    let url = dir.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: url, atomically: true, encoding: .utf8)
  }
  return dir.path
}

private func text(_ root: String, _ path: String) -> String { (try? String(contentsOfFile: root + "/" + path, encoding: .utf8)) ?? "" }

@Test func searchFindsMatchesAcrossFilesInPathOrder() throws {
  let root = try makeRoot(["b.txt": "one\nneedle two", "a/x.txt": "needle", "c.txt": "none"])
  let result = try FileService(root: root).search(query: "needle", options: SearchOptions())
  #expect(result.matches.map(\.path) == ["a/x.txt", "b.txt"])
  #expect(result.matches[1].line == 2)
  #expect(result.fileCount == 2)
  #expect(!result.truncated)
}

@Test func searchSkipsNoiseBinaryAndOversizeFiles() throws {
  let root = try makeRoot(["node_modules/x.js": "needle", ".git/config": "needle", "src/ok.txt": "needle"])
  try Data([0x6E, 0x00, 0x6E, 0x65, 0x65, 0x64, 0x6C, 0x65]).write(to: URL(fileURLWithPath: root + "/bin.dat"))
  try Data(repeating: 0x6E, count: FileService.maxBytes + 1).write(to: URL(fileURLWithPath: root + "/big.txt"))
  try Data([0xC3, 0x28]).write(to: URL(fileURLWithPath: root + "/latin.txt"))
  let result = try FileService(root: root).search(query: "needle", options: SearchOptions())
  #expect(result.matches.map(\.path) == ["src/ok.txt"])
}

@Test func searchStopsAtTheLimitAndSaysSo() throws {
  let root = try makeRoot(["a.txt": String(repeating: "x\n", count: 50)])
  let result = try FileService(root: root).search(query: "x", options: SearchOptions(), limit: 10)
  #expect(result.matches.count == 10)
  #expect(result.truncated)
}

@Test func aCancelledSearchThrows() throws {
  let root = try makeRoot(["a.txt": "x"])
  #expect(throws: SearchError.cancelled) { try FileService(root: root).search(query: "x", options: SearchOptions(), isCancelled: { true }) }
}

@Test func replaceRewritesEveryMatchingFileAndCountsThem() throws {
  let root = try makeRoot(["a.txt": "foo foo\nbar", "b.txt": "foo", "c.txt": "none"])
  let result = try FileService(root: root).replace(query: "foo", options: SearchOptions(), replacement: "baz")
  #expect(result.replacements == 3)
  #expect(result.files == 2)
  #expect(text(root, "a.txt") == "baz baz\nbar")
  #expect(text(root, "b.txt") == "baz")
  #expect(text(root, "c.txt") == "none")
}

@Test func aLiteralReplacementKeepsDollarsAndBackslashes() throws {
  let root = try makeRoot(["a.txt": "price"])
  _ = try FileService(root: root).replace(query: "price", options: SearchOptions(), replacement: #"$1 \n $0"#)
  #expect(text(root, "a.txt") == #"$1 \n $0"#)
}

@Test func aRegexReplacementCanUseCaptureGroups() throws {
  let root = try makeRoot(["a.txt": "x=1, y=2"])
  _ = try FileService(root: root).replace(query: #"(\w)=(\d)"#, options: SearchOptions(regex: true), replacement: "$2:$1")
  #expect(text(root, "a.txt") == "1:x, 2:y")
}

@Test func replaceLeavesSkippedFilesAndReportsThem() throws {
  let root = try makeRoot(["a.txt": "foo", "b.txt": "foo"])
  let result = try FileService(root: root).replace(query: "foo", options: SearchOptions(), replacement: "bar", skipping: ["a.txt"])
  #expect(result.skipped == ["a.txt"])
  #expect(result.files == 1)
  #expect(text(root, "a.txt") == "foo")
  #expect(text(root, "b.txt") == "bar")
}

@Test func replaceCanBeLimitedToChosenFiles() throws {
  let root = try makeRoot(["a.txt": "foo", "b.txt": "foo"])
  let result = try FileService(root: root).replace(query: "foo", options: SearchOptions(), replacement: "bar", paths: ["b.txt"])
  #expect(result.files == 1)
  #expect(text(root, "a.txt") == "foo")
  #expect(text(root, "b.txt") == "bar")
}

@Test func replaceKeepsCRLFAndTheByteOrderMark() throws {
  let root = try makeRoot([:])
  try (Data([0xEF, 0xBB, 0xBF]) + Data("foo\r\nfoo\r\n".utf8)).write(to: URL(fileURLWithPath: root + "/w.txt"))
  _ = try FileService(root: root).replace(query: "foo", options: SearchOptions(), replacement: "bar")
  #expect(try Data(contentsOf: URL(fileURLWithPath: root + "/w.txt")) == Data([0xEF, 0xBB, 0xBF]) + Data("bar\r\nbar\r\n".utf8))
}

@Test func replaceRefusesEmptyMatchingPatternsAndTouchesNothing() throws {
  let root = try makeRoot(["a.txt": "abc"])
  #expect(throws: SearchError.matchesEmpty) {
    try FileService(root: root).replace(query: "x*", options: SearchOptions(regex: true), replacement: "-")
  }
  #expect(text(root, "a.txt") == "abc")
}

@Test func aReadOnlyFileFailsAloneAndIsReported() throws {
  let root = try makeRoot(["a.txt": "foo", "b.txt": "foo"])
  try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root)
  defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root) }
  let result = try FileService(root: root).replace(query: "foo", options: SearchOptions(), replacement: "bar")
  #expect(result.failed.count == 2) // the folder is read-only, so neither atomic write can happen
  #expect(result.files == 0)
  #expect(text(root, "a.txt") == "foo")
}
