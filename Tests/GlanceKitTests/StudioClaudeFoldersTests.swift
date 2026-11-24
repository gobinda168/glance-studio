import Foundation
import Testing
@testable import GlanceKit

private func temporaryBase() throws -> URL {
  let base = FileManager.default.temporaryDirectory.appendingPathComponent("links-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
  return base
}

private func inode(_ url: URL) throws -> Int {
  try #require(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int)
}

@Test func aSecondStudioLeavesTheFirstStudiosLinksAlone() throws {
  let base = try temporaryBase()
  defer { try? FileManager.default.removeItem(at: base) }
  let first = StudioClaudeFolders.prepareLinksFolder(in: base, pid: 100) { _ in true }
  let link = first.appendingPathComponent("surface.json")
  try Data("{}".utf8).write(to: link)
  let watched = try inode(first)

  let second = StudioClaudeFolders.prepareLinksFolder(in: base, pid: 200) { _ in true }

  #expect(second.path != first.path)
  #expect(try inode(first) == watched)
  #expect(FileManager.default.fileExists(atPath: link.path))
}

@Test func aStudioThatIsGoneLosesItsLinksFolder() throws {
  let base = try temporaryBase()
  defer { try? FileManager.default.removeItem(at: base) }
  let gone = StudioClaudeFolders.prepareLinksFolder(in: base, pid: 100) { _ in true }

  _ = StudioClaudeFolders.prepareLinksFolder(in: base, pid: 200) { $0 != 100 }

  #expect(!FileManager.default.fileExists(atPath: gone.path))
}

@Test func aLaunchReusingAPidStartsWithAnEmptyFolder() throws {
  let base = try temporaryBase()
  defer { try? FileManager.default.removeItem(at: base) }
  let old = StudioClaudeFolders.prepareLinksFolder(in: base, pid: 100) { _ in true }
  try Data("{}".utf8).write(to: old.appendingPathComponent("surface.json"))

  let again = StudioClaudeFolders.prepareLinksFolder(in: base, pid: 100) { _ in true }

  #expect(try FileManager.default.contentsOfDirectory(atPath: again.path).isEmpty)
}

@Test func onlyLinksFoldersAreSwept() throws {
  let base = try temporaryBase()
  defer { try? FileManager.default.removeItem(at: base) }
  let keep = ["plugins", "session-links", "session-links-notapid"]
  for name in keep {
    try FileManager.default.createDirectory(at: base.appendingPathComponent(name), withIntermediateDirectories: true)
  }

  _ = StudioClaudeFolders.prepareLinksFolder(in: base, pid: 200) { _ in false }

  for name in keep { #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent(name).path)) }
}
