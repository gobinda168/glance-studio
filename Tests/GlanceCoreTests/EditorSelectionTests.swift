import Testing
@testable import GlanceCore

@Test func selectionMessagesCarryOneBasedLines() {
  #expect(EditorRequest(body: ["type": "selection", "start": 3, "end": 7]) == .selection(lines: 3...7))
  #expect(EditorRequest(body: ["type": "selection", "start": 4, "end": 4]) == .selection(lines: 4...4))
}

@Test func anEmptyOrBrokenSelectionIsNone() {
  #expect(EditorRequest(body: ["type": "selection"]) == .selection(lines: nil))
  #expect(EditorRequest(body: ["type": "selection", "start": 0, "end": 2]) == .selection(lines: nil))
  #expect(EditorRequest(body: ["type": "selection", "start": 9, "end": 2]) == .selection(lines: nil))
}
