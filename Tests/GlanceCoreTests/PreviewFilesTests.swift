import Foundation
import Testing
@testable import GlanceCore

@Test func previewURLsNameProjectPaths() {
  #expect(PreviewFiles.path(from: URL(string: "glance-file://project/docs/a%20b.png")!) == "docs/a b.png")
  #expect(PreviewFiles.path(from: URL(string: "glance-file://project/README.md")!) == "README.md")
  #expect(PreviewFiles.path(from: URL(string: "glance-file://project/")!) == nil)
  #expect(PreviewFiles.path(from: URL(string: "glance-file://other/a.png")!) == nil)
  #expect(PreviewFiles.path(from: URL(string: "file:///etc/passwd")!) == nil)
  #expect(PreviewFiles.path(from: URL(string: "https://project/a.png")!) == nil)
}

@Test func previewMimeTypes() {
  #expect(PreviewFiles.mimeType(forPath: "a/b.CSS") == "text/css")
  #expect(PreviewFiles.mimeType(forPath: "logo.svg") == "image/svg+xml")
  #expect(PreviewFiles.mimeType(forPath: "x.unknown") == "application/octet-stream")
  #expect(PreviewFiles.mimeType(forPath: "Makefile") == "application/octet-stream")
}

@Test func readDataServesAnyFileInsideTheRootOnly() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glance-pv-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir.appendingPathComponent("img"), withIntermediateDirectories: true)
  let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0, 1, 2])
  try bytes.write(to: dir.appendingPathComponent("img/logo.png"))
  let files = FileService(root: dir.path)
  #expect(try files.readData("img/logo.png") == bytes)
  #expect(throws: FileService.Failure.tooLarge) { try files.readData("img/logo.png", limit: 3) }
  #expect(throws: FileService.Failure.notAFile) { try files.readData("img") }
  #expect(throws: FileService.Failure.outsideRoot) { try files.readData("../x.png") }
  #expect(throws: FileService.Failure.notFound) { try files.readData("missing.png") }
}
