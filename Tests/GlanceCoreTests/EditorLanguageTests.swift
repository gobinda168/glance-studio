import Testing
@testable import GlanceCore

@Test func extensionsMapToMonacoLanguages() {
  #expect(EditorLanguage.id(forPath: "Sources/App.swift") == "swift")
  #expect(EditorLanguage.id(forPath: "a/b.TSX") == "typescript")
  #expect(EditorLanguage.id(forPath: "x.mjs") == "javascript")
  #expect(EditorLanguage.id(forPath: "package.json") == "json")
  #expect(EditorLanguage.id(forPath: "run.zsh") == "shell")
  #expect(EditorLanguage.id(forPath: "notes.md") == "markdown")
  #expect(EditorLanguage.id(forPath: "ci.yml") == "yaml")
  #expect(EditorLanguage.id(forPath: "Makefile") == "plaintext")
  #expect(EditorLanguage.id(forPath: ".env") == "plaintext")
}
