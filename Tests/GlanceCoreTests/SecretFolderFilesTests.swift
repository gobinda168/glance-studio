import Darwin
import Foundation
import Testing
@testable import GlanceCore

/// `body_file` and `save_to` are checked early by path, then opened again at the moment of use by walking file
/// descriptors from the session folder, so nothing swapped in between can lead outside it.
@Suite struct SecretFolderFilesTests {
  let manager = FileManager.default

  func folders() throws -> (folder: URL, outside: URL, cleanup: () -> Void) {
    let temp = realpath(manager.temporaryDirectory.path, nil)!
    defer { free(temp) }
    let base = URL(fileURLWithPath: String(cString: temp))
      .appendingPathComponent("folder-files-\(UUID().uuidString)")
    let folder = base.appendingPathComponent("project")
    let outside = base.appendingPathComponent("outside")
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    try manager.createDirectory(at: outside, withIntermediateDirectories: true)
    return (folder, outside, { try? manager.removeItem(at: base) })
  }

  func locate(_ path: String, _ folder: URL) throws -> SecretFolderFile {
    try SecretFolderFile.locate(path, inside: folder.path).get()
  }

  @Test func readsAndWritesAPlainFileInASubfolder() throws {
    let (folder, _, cleanup) = try folders()
    defer { cleanup() }
    try manager.createDirectory(at: folder.appendingPathComponent("data"), withIntermediateDirectories: true)
    let file = try locate("data/out.txt", folder)
    #expect(file.url.path == folder.appendingPathComponent("data/out.txt").path)
    #expect(file.write(Data("hello".utf8)) == nil)
    #expect(try Data(contentsOf: folder.appendingPathComponent("data/out.txt")) == Data("hello".utf8))
    #expect(file.read(limit: 100) == .success(Data("hello".utf8)))
    // Replacing an existing file works, and leaves no temp file behind.
    #expect(file.write(Data("again".utf8)) == nil)
    #expect(try manager.contentsOfDirectory(atPath: folder.appendingPathComponent("data").path) == ["out.txt"])
    #expect(try Data(contentsOf: folder.appendingPathComponent("data/out.txt")) == Data("again".utf8))
    let mode = try manager.attributesOfItem(atPath: folder.appendingPathComponent("data/out.txt").path)[.posixPermissions]
    #expect(mode as? Int == 0o600)
  }

  @Test func anIntermediateFolderSwappedForASymlinkAfterTheCheckIsRefused() throws {
    let (folder, outside, cleanup) = try folders()
    defer { cleanup() }
    let data = folder.appendingPathComponent("data")
    try manager.createDirectory(at: data, withIntermediateDirectories: true)
    try Data("ssh-rsa mine".utf8).write(to: outside.appendingPathComponent("credentials"))
    let target = try locate("data/authorized_keys", folder)
    let source = try locate("data/credentials", folder)
    try manager.removeItem(at: data)
    try manager.createSymbolicLink(at: data, withDestinationURL: outside)

    #expect(target.write(Data("ssh-rsa attacker".utf8)) == .outside)
    #expect(try manager.contentsOfDirectory(atPath: outside.path) == ["credentials"])
    #expect(source.read(limit: 100) == .failure(.outside))
  }

  @Test func aHardLinkToAnOutsideFileIsNotRead() throws {
    let (folder, outside, cleanup) = try folders()
    defer { cleanup() }
    let credentials = outside.appendingPathComponent("credentials")
    try Data("aws_secret_access_key=xyz".utf8).write(to: credentials)
    try manager.linkItem(at: credentials, to: folder.appendingPathComponent("body.txt"))
    #expect(try locate("body.txt", folder).read(limit: 100) == .failure(.notAFile))
  }

  @Test func aFIFOOrFolderIsNotReadAndDoesNotHang() throws {
    let (folder, _, cleanup) = try folders()
    defer { cleanup() }
    let fifo = folder.appendingPathComponent("pipe")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    #expect(try locate("pipe", folder).read(limit: 100) == .failure(.notAFile))
    try manager.createDirectory(at: folder.appendingPathComponent("dir"), withIntermediateDirectories: true)
    #expect(try locate("dir", folder).read(limit: 100) == .failure(.notAFile))
  }

  @Test func aSymlinkAtTheFileItselfIsNotFollowed() throws {
    let (folder, outside, cleanup) = try folders()
    defer { cleanup() }
    let victim = outside.appendingPathComponent("authorized_keys")
    try Data("mine".utf8).write(to: victim)
    let file = try locate("out.txt", folder)
    // Appears after the early check, which refuses an existing one.
    try manager.createSymbolicLink(at: folder.appendingPathComponent("out.txt"), withDestinationURL: victim)
    #expect(file.write(Data("attacker".utf8)) == .notAFile)
    #expect(file.read(limit: 100) == .failure(.outside))
    #expect(try Data(contentsOf: victim) == Data("mine".utf8))
    #expect(try manager.destinationOfSymbolicLink(atPath: folder.appendingPathComponent("out.txt").path) == victim.path)
  }

  @Test func aFolderAtTheTargetIsNotReplaced() throws {
    let (folder, _, cleanup) = try folders()
    defer { cleanup() }
    let file = try locate("out", folder)
    try manager.createDirectory(at: folder.appendingPathComponent("out"), withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: folder.appendingPathComponent("out/inner.txt"))
    #expect(file.write(Data("x".utf8)) == .notAFile)
    #expect(try manager.contentsOfDirectory(atPath: folder.path) == ["out"])
    #expect(try Data(contentsOf: folder.appendingPathComponent("out/inner.txt")) == Data("keep".utf8))
  }

  @Test func aHardLinkedTargetIsReplacedNotWrittenThrough() throws {
    let (folder, outside, cleanup) = try folders()
    defer { cleanup() }
    let victim = outside.appendingPathComponent("authorized_keys")
    try Data("mine".utf8).write(to: victim)
    try manager.linkItem(at: victim, to: folder.appendingPathComponent("out.txt"))
    #expect(try locate("out.txt", folder).write(Data("attacker".utf8)) == nil)
    #expect(try Data(contentsOf: victim) == Data("mine".utf8))
    #expect(try Data(contentsOf: folder.appendingPathComponent("out.txt")) == Data("attacker".utf8))
  }

  @Test func theFolderIsPinnedWhenTheFileIsLocated() throws {
    let (folder, outside, cleanup) = try folders()
    defer { cleanup() }
    let file = try locate("out.txt", folder)
    let moved = folder.deletingLastPathComponent().appendingPathComponent("moved")
    try manager.moveItem(at: folder, to: moved)
    try manager.createSymbolicLink(at: folder, withDestinationURL: outside)
    _ = file.write(Data("x".utf8))
    #expect(try manager.contentsOfDirectory(atPath: outside.path).isEmpty)
  }

  @Test func aFileOverTheLimitIsNotRead() throws {
    let (folder, _, cleanup) = try folders()
    defer { cleanup() }
    try Data(repeating: 0x61, count: 11).write(to: folder.appendingPathComponent("big.txt"))
    #expect(try locate("big.txt", folder).read(limit: 10) == .failure(.tooLarge))
    #expect(try locate("big.txt", folder).read(limit: 11) == .success(Data(repeating: 0x61, count: 11)))
  }

  @Test func theEarlyCheckStillRefusesWhatThePolicyRefuses() throws {
    let (folder, _, cleanup) = try folders()
    defer { cleanup() }
    #expect(throws: SecretRequestPolicy.Refusal.self) { try locate("../x", folder) }
    #expect(throws: SecretRequestPolicy.Refusal.self) { try locate("missing/x", folder) }
    #expect(throws: SecretRequestPolicy.Refusal.noFolder) { try SecretFolderFile.locate("x", inside: nil).get() }
  }

  @Test func aMissingFileIsAFailureNotARefusal() throws {
    let (folder, _, cleanup) = try folders()
    defer { cleanup() }
    #expect(try locate("nope.txt", folder).read(limit: 10) == .failure(.failed))
  }
}
