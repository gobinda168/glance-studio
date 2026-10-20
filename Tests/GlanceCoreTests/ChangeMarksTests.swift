import Testing
@testable import GlanceCore

private func marks(_ text: String, _ changes: FileEdit.Change...) -> [LineMark] {
  ChangeMarks.marks(in: text, changes: changes)
}
private func replace(_ old: String, _ new: String, all: Bool = false) -> FileEdit.Change { .replace(old: old, new: new, replaceAll: all) }

@Test func onlyTheChangedLineIsMarkedNotItsContext() {
  // Claude sent a/b/c → a/B/c as a three-line edit; only line 3 of the file changed.
  #expect(marks("x\na\nB\nc\ny", replace("a\nb\nc", "a\nB\nc")) == [LineMark(start: 3, end: 3, kind: .modified)])
}

@Test func insertedLinesAreAdded() {
  #expect(marks("x\na\nb\nc", replace("a\nc", "a\nb\nc")) == [LineMark(start: 3, end: 3, kind: .added)])
}

@Test func aMultiLineReplacementMarksEveryNewLine() {
  #expect(marks("1\nbar\nbaz\n4", replace("foo", "bar\nbaz")) == [LineMark(start: 2, end: 3, kind: .modified)])
}

@Test func removedLinesLeaveADeletionMarkWhereTheyWere() {
  #expect(marks("a\nc", replace("a\nX\nc", "a\nc")) == [LineMark(start: 2, end: 2, kind: .deleted)])
}

@Test func anEditThatChangesNothingMarksNothing() {
  #expect(marks("a\nb", replace("a\nb", "a\nb")).isEmpty)
}

@Test func textThatIsNoLongerInTheFileOrIsEmptyMarksNothing() {
  #expect(marks("completely different", replace("a", "gone")).isEmpty)
  #expect(marks("a\nb", replace("a\nX\nb", "")).isEmpty)
}

@Test func replaceAllMarksEveryOccurrence() {
  #expect(marks("v\nx\nv\nx\nv", replace("old", "v", all: true)) == [
    LineMark(start: 1, end: 1, kind: .modified), LineMark(start: 3, end: 3, kind: .modified), LineMark(start: 5, end: 5, kind: .modified),
  ])
}

@Test func aWriteMarksTheWholeFile() {
  #expect(marks("a\nb\nc", .write(content: "a\nb\nc")) == [LineMark(start: 1, end: 3, kind: .modified)])
}

@Test func neighbouringEditsMergeAndFarOnesStayApart() {
  let text = "a\nB\nC\nd\ne\nF"
  #expect(marks(text, replace("b", "B"), replace("c", "C"), replace("f", "F")) == [
    LineMark(start: 2, end: 3, kind: .modified), LineMark(start: 6, end: 6, kind: .modified),
  ])
}

@Test func unicodeBeforeTheChangeDoesNotShiftTheLine() {
  #expect(marks("🙂é\nline\nNEW", replace("old", "NEW")) == [LineMark(start: 3, end: 3, kind: .modified)])
}

@Test func marksStayInsideTheFile() {
  // The deletion point is the last line when the removed lines were at the end.
  #expect(marks("a", replace("a\nX", "a")) == [LineMark(start: 1, end: 1, kind: .deleted)])
}
