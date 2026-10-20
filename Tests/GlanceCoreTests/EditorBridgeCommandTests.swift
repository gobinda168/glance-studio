import Foundation
import Testing
@testable import GlanceCore

private func object(_ line: String) throws -> [String: Any] {
  try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
}

@Test func opensAFileAtALineAndColumn() throws {
  let line = EditorBridgeCommand.open(path: "/Users/u/My Project/Sources/é.swift", line: 42, column: 7).line
  #expect(!line.contains("\n"))
  let json = try object(line)
  #expect(json["type"] as? String == "open")
  #expect(json["path"] as? String == "/Users/u/My Project/Sources/é.swift")
  #expect(json["line"] as? Int == 42)
  #expect(json["column"] as? Int == 7)
}

@Test func leavesOutAMissingLineOrColumn() throws {
  let json = try object(EditorBridgeCommand.open(path: "/p/a.swift", line: nil, column: nil).line)
  #expect(json["line"] == nil && json["column"] == nil)
}

@Test func sendsClaudesMarksByRelativePath() throws {
  let marks: [String: [LineMark]] = [
    "Sources/a b.swift": [LineMark(start: 3, end: 5, kind: .added), LineMark(start: 9, end: 9, kind: .deleted)],
  ]
  let json = try object(EditorBridgeCommand.claudeChanges(marks).line)
  #expect(json["type"] as? String == "claudeChanges")
  let files = try #require(json["files"] as? [String: [[String: Any]]])
  let list = try #require(files["Sources/a b.swift"])
  #expect(list.count == 2)
  #expect(list[0]["start"] as? Int == 3 && list[0]["end"] as? Int == 5 && list[0]["kind"] as? String == "added")
  #expect(list[1]["kind"] as? String == "deleted")
}

@Test func anEmptyMapClearsTheMarks() throws {
  let json = try object(EditorBridgeCommand.claudeChanges([:]).line)
  #expect((json["files"] as? [String: Any])?.isEmpty == true)
}
