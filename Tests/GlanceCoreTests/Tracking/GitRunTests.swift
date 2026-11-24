import Foundation
import Testing
@testable import GlanceCore

private func scratchFolder() throws -> String {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gitrun-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  return folder.path
}

struct GitRunTests {
  @Test func textReturnsGitsOutput() throws {
    let folder = try scratchFolder()
    let version = try #require(GitRun.text(folder, ["--version"]))
    #expect(version.hasPrefix("git version"))
  }

  @Test func aFailingCommandReturnsNil() throws {
    let folder = try scratchFolder()
    #expect(GitRun.text(folder, ["init", "-q"]) != nil)
    #expect(GitRun.text(folder, ["rev-parse", "--verify", "nope"]) == nil)
  }

  @Test func aMissingFolderReturnsNil() {
    #expect(GitRun.data("/nonexistent-\(UUID().uuidString)", ["status"]) == nil)
  }
}
