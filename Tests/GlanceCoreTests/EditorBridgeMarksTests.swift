import Foundation
import Testing
@testable import GlanceCore

@Test func claudeChangesReachThePageByPath() throws {
  let script = EditorReply.claudeChanges([
    "src/é.swift": [LineMark(start: 3, end: 5, kind: .modified), LineMark(start: 9, end: 9, kind: .deleted)],
    "b.txt": [],
  ])
  let prefix = "editorHost.claudeChanges("
  #expect(script.hasPrefix(prefix))
  let object = try #require(JSONSerialization.jsonObject(with: Data(script.dropFirst(prefix.count).dropLast().utf8)) as? [String: Any])
  let marks = try #require(object["src/é.swift"] as? [[String: Any]])
  #expect(marks.count == 2)
  #expect(marks[0]["start"] as? Int == 3)
  #expect(marks[0]["end"] as? Int == 5)
  #expect(marks[0]["kind"] as? String == "modified")
  #expect(marks[1]["kind"] as? String == "deleted")
  #expect((object["b.txt"] as? [Any])?.isEmpty == true)
}
