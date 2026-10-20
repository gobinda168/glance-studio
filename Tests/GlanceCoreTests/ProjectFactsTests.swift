import Foundation
import Testing
@testable import GlanceCore

@Test func readsScriptsAndBranchesFromFiles() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("facts-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: root) }
  let fm = FileManager.default
  try fm.createDirectory(at: root.appendingPathComponent(".git/refs/heads/feature"), withIntermediateDirectories: true)
  try "x".write(to: root.appendingPathComponent(".git/refs/heads/main"), atomically: true, encoding: .utf8)
  try "x".write(to: root.appendingPathComponent(".git/refs/heads/feature/login"), atomically: true, encoding: .utf8)
  try "# pack-refs\nabc refs/heads/old\n^def\nabc refs/tags/v1\n".write(
    to: root.appendingPathComponent(".git/packed-refs"), atomically: true, encoding: .utf8)
  try #"{"name":"x","scripts":{"dev":"vite","build":"vite build"}}"#.write(
    to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
  try fm.createDirectory(at: root.appendingPathComponent("src/deep"), withIntermediateDirectories: true)
  let deep = root.appendingPathComponent("src/deep").path
  #expect(ProjectFacts.scripts(inFolder: deep) == ["build", "dev"])
  #expect(ProjectFacts.branches(inFolder: deep) == ["feature/login", "main", "old"])
  #expect(ProjectFacts.scripts(inFolder: "/") == [])
}
