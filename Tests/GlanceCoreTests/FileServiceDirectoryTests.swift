import Foundation
import Testing
@testable import GlanceCore

private func makeRoot(_ files: [String]) throws -> String {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glance-ls-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  for path in files {
    let url = dir.appendingPathComponent(path)
    if path.hasSuffix("/") {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    } else {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try "x".write(to: url, atomically: true, encoding: .utf8)
    }
  }
  return dir.path
}

@Test func foldersComeFirstThenFilesEachSortedIgnoringCase() throws {
  let root = try makeRoot(["b.txt", "A.txt", "zeta/", "Alpha/", "src/main.swift"])
  let entries = try FileService(root: root).listDirectory("")
  #expect(entries.map(\.name) == ["Alpha", "src", "zeta", "A.txt", "b.txt"])
  #expect(entries.map(\.isDirectory) == [true, true, true, false, false])
}

@Test func aSubfolderListsItsOwnEntries() throws {
  let root = try makeRoot(["src/a.swift", "src/lib/b.swift", "top.txt"])
  let files = FileService(root: root)
  #expect(try files.listDirectory("src").map(\.name) == ["lib", "a.swift"])
  #expect(try files.listDirectory("src/lib").map(\.name) == ["b.swift"])
}

@Test func theUsualNoiseIsHidden() throws {
  let root = try makeRoot([".git/config", "node_modules/x/y.js", "build/o", "dist/o", ".DS_Store", ".gitignore", "README.md"])
  #expect(try FileService(root: root).listDirectory("").map(\.name) == [".gitignore", "README.md"])
}

@Test func symlinksAreNotListed() throws {
  let root = try makeRoot(["real.txt", "realdir/"])
  try FileManager.default.createSymbolicLink(atPath: root + "/link.txt", withDestinationPath: root + "/real.txt")
  try FileManager.default.createSymbolicLink(atPath: root + "/linkdir", withDestinationPath: root + "/realdir")
  #expect(try FileService(root: root).listDirectory("").map(\.name) == ["realdir", "real.txt"])
}

@Test func unicodeAndSpacesSurvive() throws {
  let root = try makeRoot(["my notes/été 🙂.md"])
  let files = FileService(root: root)
  #expect(try files.listDirectory("").map(\.name) == ["my notes"])
  #expect(try files.listDirectory("my notes").map(\.name) == ["été 🙂.md"])
}

@Test func foldersOutsideTheRootAreRefused() throws {
  let root = try makeRoot(["a.txt"])
  let files = FileService(root: root)
  for path in ["..", "../x", "/etc", "a/../.."] {
    #expect(throws: FileService.Failure.outsideRoot) { try files.listDirectory(path) }
  }
}

@Test func filesAndMissingFoldersAreErrors() throws {
  let root = try makeRoot(["a.txt"])
  let files = FileService(root: root)
  #expect(throws: FileService.Failure.notADirectory) { try files.listDirectory("a.txt") }
  #expect(throws: FileService.Failure.notFound) { try files.listDirectory("nope") }
}

@Test func theRootIsListedForDotToo() throws {
  let root = try makeRoot(["a.txt"])
  #expect(try FileService(root: root).listDirectory(".").map(\.name) == ["a.txt"])
}
