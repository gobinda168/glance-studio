import Foundation
import Testing
@testable import GlanceCore

private func makeRoot(_ files: [String: String] = [:]) throws -> String {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glance-fs-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  for (path, content) in files {
    let url = dir.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: url, atomically: true, encoding: .utf8)
  }
  return dir.path
}

private func write(_ data: Data, _ root: String, _ path: String) throws {
  try data.write(to: URL(fileURLWithPath: root).appendingPathComponent(path))
}

@Test func readsTextAndTheModificationTime() throws {
  let root = try makeRoot(["a/b.txt": "héllo\n"])
  let doc = try FileService(root: root).read("a/b.txt")
  #expect(doc.text == "héllo\n")
  #expect(doc.path == "a/b.txt")
  #expect(!doc.bom)
  #expect(doc.modified > 1_000_000_000)
}

@Test func refusesPathsOutsideTheRoot() throws {
  let root = try makeRoot(["inside.txt": "x"])
  let outside = try makeRoot(["secret.txt": "s"])
  try FileManager.default.createSymbolicLink(atPath: root + "/link.txt", withDestinationPath: outside + "/secret.txt")
  let files = FileService(root: root)
  for path in ["../x", "/etc/passwd", "a/../../x", "link.txt", ""] {
    #expect(throws: FileService.Failure.outsideRoot) { try files.read(path) }
    #expect(throws: FileService.Failure.outsideRoot) { try files.save(path, text: "no", expectedModified: nil, bom: false) }
  }
  #expect((try? String(contentsOfFile: outside + "/secret.txt", encoding: .utf8)) == "s")
}

@Test func refusesBinaryOversizeAndNonUTF8() throws {
  let root = try makeRoot()
  try write(Data([0x68, 0x00, 0x69]), root, "bin.dat")
  try write(Data(repeating: 0x61, count: FileService.maxBytes + 1), root, "big.txt")
  try write(Data([0xC3, 0x28]), root, "latin.txt")
  let files = FileService(root: root)
  #expect(throws: FileService.Failure.binary) { try files.read("bin.dat") }
  #expect(throws: FileService.Failure.tooLarge) { try files.read("big.txt") }
  #expect(throws: FileService.Failure.notUTF8) { try files.read("latin.txt") }
  #expect(throws: FileService.Failure.notFound) { try files.read("missing.txt") }
  #expect(throws: FileService.Failure.notAFile) { try files.read(".") }
}

@Test func keepsTheByteOrderMark() throws {
  let root = try makeRoot()
  try write(Data([0xEF, 0xBB, 0xBF]) + Data("hi".utf8), root, "bom.txt")
  let files = FileService(root: root)
  let doc = try files.read("bom.txt")
  #expect(doc.text == "hi")
  #expect(doc.bom)
  _ = try files.save("bom.txt", text: "hey", expectedModified: doc.modified, bom: true)
  #expect(try Data(contentsOf: URL(fileURLWithPath: root + "/bom.txt")) == Data([0xEF, 0xBB, 0xBF]) + Data("hey".utf8))
}

@Test func keepsCRLFExactlyAsGiven() throws {
  let root = try makeRoot()
  try write(Data("a\r\nb\r\n".utf8), root, "w.txt")
  let files = FileService(root: root)
  let doc = try files.read("w.txt")
  #expect(doc.text == "a\r\nb\r\n")
  _ = try files.save("w.txt", text: doc.text + "c\r\n", expectedModified: doc.modified, bom: false)
  #expect(try String(contentsOfFile: root + "/w.txt", encoding: .utf8) == "a\r\nb\r\nc\r\n")
}

@Test func saveIsAtomicKeepsPermissionsAndReturnsTheNewTime() throws {
  let root = try makeRoot(["run.sh": "echo 1\n"])
  let path = root + "/run.sh"
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
  let files = FileService(root: root)
  let doc = try files.read("run.sh")
  let modified = try files.save("run.sh", text: "echo 2\n", expectedModified: doc.modified, bom: false)
  #expect(try String(contentsOfFile: path, encoding: .utf8) == "echo 2\n")
  #expect(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int == 0o755)
  #expect(files.modified("run.sh") == modified)
  #expect(try FileManager.default.contentsOfDirectory(atPath: root) == ["run.sh"]) // no temp file left
}

@Test func saveRefusesWhenTheFileChangedOnDisk() throws {
  let root = try makeRoot(["f.txt": "one"])
  let files = FileService(root: root)
  let doc = try files.read("f.txt")
  try "two".write(toFile: root + "/f.txt", atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: root + "/f.txt")
  #expect(throws: FileService.Failure.changedOnDisk) { try files.save("f.txt", text: "mine", expectedModified: doc.modified, bom: false) }
  #expect(try String(contentsOfFile: root + "/f.txt", encoding: .utf8) == "two")
  _ = try files.save("f.txt", text: "mine", expectedModified: nil, bom: false) // overwrite is the user's choice
  #expect(try String(contentsOfFile: root + "/f.txt", encoding: .utf8) == "mine")
}

@Test func aDeletedFileIsOnlyRecreatedWhenForced() throws {
  let root = try makeRoot(["gone.txt": "x"])
  let files = FileService(root: root)
  let doc = try files.read("gone.txt")
  try FileManager.default.removeItem(atPath: root + "/gone.txt")
  #expect(files.modified("gone.txt") == nil)
  #expect(throws: FileService.Failure.changedOnDisk) { try files.save("gone.txt", text: "y", expectedModified: doc.modified, bom: false) }
  _ = try files.save("gone.txt", text: "y", expectedModified: nil, bom: false)
  #expect(try String(contentsOfFile: root + "/gone.txt", encoding: .utf8) == "y")
}

@Test func aReadOnlyFileFailsToSaveWithoutTouchingIt() throws {
  let root = try makeRoot(["ro.txt": "keep"])
  try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: root + "/ro.txt")
  try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root)
  defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root) }
  let files = FileService(root: root)
  let doc = try files.read("ro.txt")
  #expect(throws: (any Error).self) { try files.save("ro.txt", text: "lost", expectedModified: doc.modified, bom: false) }
  #expect(try String(contentsOfFile: root + "/ro.txt", encoding: .utf8) == "keep")
}

@Test func listsFilesWithoutTheUsualNoise() throws {
  let root = try makeRoot([
    "README.md": "", ".gitignore": "", "src/a.swift": "", "node_modules/x/y.js": "", ".git/config": "",
    "build/out.o": "", "src/.DS_Store": "",
  ])
  #expect(FileService(root: root).listFiles() == [".gitignore", "README.md", "src/a.swift"])
}

@Test func listingIsCapped() throws {
  let root = try makeRoot((0..<30).reduce(into: [:]) { $0["f\($1).txt"] = "" })
  #expect(FileService(root: root).listFiles(limit: 10).count == 10)
}

@Test func inAGitRepoTheListingIsTrackedPlusUntrackedMinusIgnoredAndDeleted() throws {
  let root = try makeRoot(["tracked.txt": "", "gone.txt": "", ".gitignore": "ignored.txt\n", "ignored.txt": ""])
  func git(_ args: String...) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", root] + args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
  }
  try git("init", "-q")
  try git("add", "tracked.txt", "gone.txt", ".gitignore")
  try FileManager.default.removeItem(atPath: root + "/gone.txt")
  try "u".write(toFile: root + "/untracked.txt", atomically: true, encoding: .utf8)
  #expect(FileService(root: root).listFiles().sorted() == [".gitignore", "tracked.txt", "untracked.txt"])
}

@Test func createsFilesAndFoldersWithTheFoldersAboveThem() throws {
  let root = try makeRoot(["a/b.txt": "x"])
  let files = FileService(root: root)
  try files.create("a/new.ts", directory: false)
  try files.create("c/d/e.md", directory: false)
  try files.create("f/g", directory: true)
  #expect(try files.read("a/new.ts").text == "")
  #expect(try files.read("c/d/e.md").text == "")
  #expect(try files.listDirectory("f") == [.init(name: "g", isDirectory: true)])
}

@Test func createRefusesWhatIsAlreadyThere() throws {
  let root = try makeRoot(["a/b.txt": "keep"])
  let files = FileService(root: root)
  try FileManager.default.createSymbolicLink(atPath: root + "/broken", withDestinationPath: root + "/nowhere")
  #expect(throws: FileService.Failure.exists) { try files.create("a/b.txt", directory: false) }
  #expect(throws: FileService.Failure.exists) { try files.create("a", directory: true) }
  #expect(throws: FileService.Failure.exists) { try files.create("broken", directory: false) }
  #expect(try files.read("a/b.txt").text == "keep")
  #expect(!FileManager.default.fileExists(atPath: root + "/nowhere"))
}

@Test func createStaysInsideTheRoot() throws {
  let root = try makeRoot(["a.txt": "x"])
  let outside = try makeRoot()
  try FileManager.default.createSymbolicLink(atPath: root + "/out", withDestinationPath: outside)
  let files = FileService(root: root)
  for path in ["../x", "/tmp/x", "out/x.txt", "out/deep/x.txt", ""] {
    #expect(throws: FileService.Failure.outsideRoot) { try files.create(path, directory: false) }
  }
  #expect(throws: FileService.Failure.notADirectory) { try files.create("a.txt/x", directory: false) }
  #expect(try FileManager.default.contentsOfDirectory(atPath: outside).isEmpty)
}
