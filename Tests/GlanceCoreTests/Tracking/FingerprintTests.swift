import Foundation
import Testing
@testable import GlanceCore

struct FingerprintTests {
  @Test func parsesPorcelainV2Entries() {
    // Ordinary change, rename (its original path follows as its own field), unmerged, untracked.
    let raw = "1 .M N... 100644 100644 100644 aaa bbb src/a b.swift\u{0}"
      + "2 R. N... 100644 100644 100644 aaa bbb R100 new.txt\u{0}old.txt\u{0}"
      + "u UU N... 100644 100644 100644 100644 aaa bbb ccc conflict.txt\u{0}"
      + "? notes/todo.md\u{0}"
    let parsed = Fingerprint.parseStatus(Data(raw.utf8))
    #expect(parsed.map(\.path) == ["src/a b.swift", "new.txt", "conflict.txt", "notes/todo.md"])
    #expect(parsed.map(\.status) == [".M", "R.", "UU", "??"])
  }

  @Test func takeReusesHashesOfUnchangedFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "one".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    var reads = 0
    let counting: (String) -> String = { reads += 1; return Fingerprint.contentHash(file: $0) }
    let first = Fingerprint.take(root: root.path, status: [("a.txt", ".M")], previous: nil, hash: counting)
    let second = Fingerprint.take(root: root.path, status: [("a.txt", ".M")], previous: first, hash: counting)
    #expect(reads == 1)
    #expect(first == second)
    // A deleted file is fingerprinted without reading it.
    let gone = Fingerprint.take(root: root.path, status: [("gone.txt", ".D")], previous: nil, hash: counting)
    #expect(gone.entries["gone.txt"]?.hash == "deleted")
    #expect(reads == 1)
  }

  @Test func changedContentListsAddedRemovedAndAlteredPaths() {
    let a = Fingerprint.Entry(status: ".M", size: 1, mtime: 1, hash: "h1")
    let before = Fingerprint(entries: ["x": a, "y": a, "staged": a, "touched": a])
    let after = Fingerprint(entries: [
      "y": Fingerprint.Entry(status: ".M", size: 2, mtime: 2, hash: "h2"), "z": a,
      // `git add` changes only the status, `touch` only the mtime: neither is a change of content.
      "staged": Fingerprint.Entry(status: "M.", size: 1, mtime: 1, hash: "h1"),
      "touched": Fingerprint.Entry(status: ".M", size: 1, mtime: 9, hash: "h1"),
    ])
    #expect(before.changedContent(to: after) == ["x", "y", "z"])
    #expect(before.changedContent(to: before).isEmpty)
  }

  @Test func bigFilesAndSymlinksAreNotRead() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let big = root.appendingPathComponent("big.bin")
    FileManager.default.createFile(atPath: big.path, contents: nil)
    let handle = try FileHandle(forWritingTo: big)
    try handle.truncate(atOffset: 9 * 1024 * 1024) // sparse: no 9 MB written
    try handle.close()
    try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path,
                                               withDestinationPath: "target/elsewhere")
    var reads = 0
    let counting: (String) -> String = { reads += 1; return Fingerprint.contentHash(file: $0) }
    let print = Fingerprint.take(root: root.path, status: [("big.bin", "??"), ("link", "??")], previous: nil,
                                 hash: counting)
    #expect(reads == 0)
    let bigHash = try #require(print.entries["big.bin"]?.hash)
    #expect(bigHash.hasPrefix("big:9437184:"))
    #expect(print.entries["link"]?.hash == "link:target/elsewhere")
    #expect(Fingerprint.hash(file: big.path) == bigHash)
    #expect(Fingerprint.hash(file: root.appendingPathComponent("link").path) == "link:target/elsewhere")
    #expect(Fingerprint.hash(file: root.path) == "special") // a folder (a submodule) isn't opened
  }

  @Test func tooManyFilesStopsFingerprinting() {
    let status = (0...Fingerprint.limit).map { ("f\($0)", "??") }
    let print = Fingerprint.take(root: "/nonexistent", status: status, previous: nil) { _ in "x" }
    #expect(print.tooMany)
    #expect(print.entries.isEmpty)
  }
}
