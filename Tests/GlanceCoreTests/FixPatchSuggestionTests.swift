import Foundation
import Testing
@testable import GlanceCore

/// A transcript line: Claude's words, then a tool it used.
private func assistant(_ name: String, _ input: [String: String]) -> String {
  let text: [String: Any] = ["type": "text", "text": "On it."]
  let use: [String: Any] = ["type": "tool_use", "name": name, "input": input]
  let entry: [String: Any] = ["type": "assistant", "message": ["content": [text, use]] as [String: Any]]
  return String(decoding: (try? JSONSerialization.data(withJSONObject: entry)) ?? Data(), as: UTF8.self)
}

@Test func aSuggestionReplacesTheLinesItWasWrittenOn() {
  #expect(FixPatch.applying(["TWO", "2b"], to: "one\ntwo\nthree\n", start: 2, end: 2, original: ["two"])
    == "one\nTWO\n2b\nthree\n")
  // A range, and one that deletes lines.
  #expect(FixPatch.applying(["X"], to: "a\nb\nc\nd", start: 2, end: 3, original: ["b", "c"]) == "a\nX\nd")
  #expect(FixPatch.applying([], to: "one\ntwo\nthree\n", start: 2, end: 2, original: ["two"]) == "one\nthree\n")
}

@Test func aSuggestionKeepsTheFilesLineEndings() {
  #expect(FixPatch.applying(["A"], to: "a\r\nb\r\n", start: 1, end: 1, original: ["a"]) == "A\r\nb\r\n")
}

@Test func aSuggestionOnLinesThatChangedSinceTheReviewIsRefused() {
  #expect(FixPatch.applying(["X"], to: "one\nTWO, edited\nthree\n", start: 2, end: 2, original: ["two"]) == nil)
  #expect(FixPatch.applying(["X"], to: "one\n", start: 9, end: 9, original: ["nine"]) == nil)
  #expect(FixPatch.applying(["X"], to: "one\n", start: 1, end: 1, original: []) == nil)
}

@Test func theFixingStripSaysWhatClaudeIsDoing() {
  let root = "/Users/me/glance"
  let tail = [#"{"type":"user","message":{"content":"Fix this review comment"}}"#,
              assistant("Read", ["file_path": "/Users/me/glance/Package.swift"]),
              assistant("Edit", ["file_path": "/Users/me/glance/scripts/release.sh"])].joined(separator: "\n")
  #expect(FixPatch.activity(transcript: tail, root: root) == "Editing scripts/release.sh")
  #expect(FixPatch.activity(transcript: assistant("Bash", ["command": "shellcheck scripts/release.sh\necho done"]),
                            root: root) == "Running shellcheck scripts/release.sh")
  #expect(FixPatch.activity(transcript: assistant("Read", ["file_path": "/elsewhere/a.swift"]), root: root)
    == "Reading /elsewhere/a.swift")
  #expect(FixPatch.activity(transcript: assistant("Grep", ["pattern": "x"]), root: root) == "Searching the project")
  #expect(FixPatch.activity(transcript: assistant("TodoWrite", [:]), root: root) == "Working")
  // A tail starts mid-line; before any tool there's nothing to say.
  #expect(FixPatch.activity(transcript: "ge\":\"x\"}}\n" + #"{"type":"user","message":{"content":"hi"}}"#, root: root)
    == nil)
}
