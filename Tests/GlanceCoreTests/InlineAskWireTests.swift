import Foundation
import Testing
@testable import GlanceCore

nonisolated(unsafe) private let fields: [String: Any] = ["id": "q7", "path": "a/b.swift", "start": 2, "end": 3, "text": "x\ny",
                                     "before": "w", "after": "z", "question": "Why?"]
private let expected = InlineAsk.Request(id: "q7", path: "a/b.swift", start: 2, end: 3, text: "x\ny", before: "w",
                                         after: "z", question: "Why?")

private func line(_ object: [String: Any]) -> String {
  String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

@Test func razorAsksStartFollowUpAndStop() {
  #expect(EditorRequest(body: fields.merging(["type": "askStart"]) { $1 }) == .askStart(expected))
  #expect(EditorRequest(body: ["type": "askFollowUp", "id": "q7", "question": "And?"]) == .askFollowUp(id: "q7", question: "And?"))
  #expect(EditorRequest(body: ["type": "askStop", "id": "q7"]) == .askStop(id: "q7"))
}

@Test func malformedAsksAreDropped() {
  #expect(EditorRequest(body: fields.merging(["type": "askStart", "start": "2"]) { $1 }) == nil)
  #expect(EditorRequest(body: ["type": "askFollowUp", "id": "q7"]) == nil)
  #expect(EditorBridgeMessage.decode(line(["type": "askStop"])) == nil)
  #expect(EditorBridgeMessage.decode(line(fields.merging(["type": "askStart", "question": NSNull()]) { $1 })) == nil)
}

@Test func studioAsksStartFollowUpAndStop() {
  #expect(EditorBridgeMessage.decode(line(fields.merging(["type": "askStart"]) { $1 })) == .askStart(expected))
  #expect(EditorBridgeMessage.decode(line(["type": "askFollowUp", "id": "q7", "question": "And?"]))
    == .askFollowUp(id: "q7", question: "And?"))
  #expect(EditorBridgeMessage.decode(line(["type": "askStop", "id": "q7"])) == .askStop(id: "q7"))
}

@Test func askEventsGoToStudioAsOneLine() throws {
  let text = EditorBridgeCommand.askEvent(.done(replacement: "new"), request: expected).line
  #expect(!text.contains("\n"))
  let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
  #expect(object["type"] as? String == "askEvent")
  #expect(object["id"] as? String == "q7")
  #expect(object["kind"] as? String == "done")
  #expect(object["replacement"] as? String == "new")
  #expect(object["originalText"] as? String == "x\ny")
}

@Test func askEventsGoToRazorAsACall() throws {
  let script = EditorReply.askEvent(.text("hi </script>"), request: expected)
  #expect(script.hasPrefix("editorHost.askEvent({"))
  #expect(script.hasSuffix("})"))
  let json = String(script.dropFirst("editorHost.askEvent(".count).dropLast())
  let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
  #expect(object["text"] as? String == "hi </script>")
  #expect(object["kind"] as? String == "text")
}
