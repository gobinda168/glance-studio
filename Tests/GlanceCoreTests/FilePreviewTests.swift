import Foundation
import Testing
@testable import GlanceCore

@Test func textAndCodeOpenInTheEditorEverythingElseInQuickLook() {
  for path in ["a.swift", "b.md", "c.json", "d.txt", "Makefile", "e.unknownext", "f.ts", "g.html"] {
    #expect(FilePreview.opensInEditor(path), "\(path)")
  }
  for path in ["a.png", "b.JPG", "c.pdf", "d.svg", "e.docx", "f.mov", "g.heic", "h.key"] {
    #expect(!FilePreview.opensInEditor(path), "\(path)")
  }
}

@Test func aPreviewRequestNamesAnExistingFile() throws {
  let file = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString).png")
  try Data([1]).write(to: file)
  defer { try? FileManager.default.removeItem(at: file) }
  #expect(FilePreview.requestedPath(Data(#"{"path":"\#(file.path)"}"#.utf8)) == file.path)
  #expect(FilePreview.requestedPath(Data(#"{"path":"/no/such/file.png"}"#.utf8)) == nil)
  #expect(FilePreview.requestedPath(Data(#"{"path":"relative.png"}"#.utf8)) == nil)
  #expect(FilePreview.requestedPath(Data(#"{"path":"/tmp"}"#.utf8)) == nil)
  #expect(FilePreview.requestedPath(Data("nope".utf8)) == nil)
}
