import Foundation
import Testing
@testable import GlanceCore

private func fixture(_ name: String) throws -> String {
  let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Fixtures/prompts/\(name).txt")
  return try String(contentsOf: url, encoding: .utf8)
}

private func screen(_ labels: [String], selected: Int = 0, checked: Bool? = nil, question: String = "Q?",
                    submitAfter: Int? = nil) -> DialogScreen {
  DialogScreen(question: question, detail: [],
               options: labels.enumerated().map { PromptOption(number: $0.offset + 1, label: $0.element, note: nil,
                                                               checked: checked) },
               selected: selected, submitAfter: submitAfter)
}

@Test func pickingAnOptionMovesThenConfirms() {
  let s = screen(["Yes", "Yes, always", "No"])
  #expect(PromptKeys.keys(.option(1), kind: .permission, screen: s) == [.enter])
  #expect(PromptKeys.keys(.option(3), kind: .permission, screen: s) == [.down, .down, .enter])
  #expect(PromptKeys.keys(.option(1), kind: .permission, screen: screen(["Yes", "No"], selected: 1)) == [.up, .enter])
  #expect(PromptKeys.keys(.option(9), kind: .permission, screen: s) == nil)
}

@Test func aPermissionNoteIsEscThenTheNote() {
  #expect(PromptKeys.keys(.note("use pnpm"), kind: .permission, screen: screen(["Yes", "No"]))
    == [.escape, .text("use pnpm"), .enter])
  #expect(PromptKeys.keys(.note("  "), kind: .permission, screen: screen(["Yes", "No"])) == nil)
}

@Test func aQuestionNoteGoesToTheFreeTextEntry() {
  let s = screen(["red", "green", "Type something."])
  #expect(PromptKeys.keys(.note("teal"), kind: .question, screen: s) == [.down, .down, .text("teal"), .enter])
  #expect(PromptKeys.keys(.note("teal"), kind: .question, screen: screen(["red", "green"])) == nil)
}

@Test func aPlanNoteKeepsPlanning() {
  let s = screen(["Yes, and auto-accept edits", "Yes, and manually approve edits", "No, keep planning"])
  #expect(PromptKeys.keys(.note("smaller steps"), kind: .plan, screen: s)
    == [.down, .down, .enter, .text("smaller steps"), .enter])
  let real = screen(["Yes, and use auto mode", "Yes, manually approve edits", "Tell Claude what to change"])
  #expect(PromptKeys.keys(.note("smaller steps"), kind: .plan, screen: real)
    == [.down, .down, .enter, .text("smaller steps"), .enter])
}

@Test func multiSelectTogglesAndSubmits() {
  let s = screen(["apple", "banana", "Submit"], checked: false)
  #expect(PromptKeys.keys(.toggle(2), kind: .question, screen: s) == [.down, PromptKeys.toggleKey])
  #expect(PromptKeys.keys(.submit, kind: .question, screen: s) == [.down, .down, .enter])
  #expect(PromptKeys.keys(.toggle(1), kind: .question, screen: screen(["a", "b"])) == nil)   // not multi-select
}

@Test func theUnnumberedSubmitRowIsAStopOfItsOwn() {
  // apple, banana, cherry, Type something, [Submit], Chat about this
  let labels = ["apple", "banana", "cherry", "Type something", "Chat about this"]
  let s = screen(labels, checked: false, submitAfter: 3)
  #expect(PromptKeys.keys(.toggle(3), kind: .question, screen: s) == [.down, .down, PromptKeys.toggleKey])
  #expect(PromptKeys.keys(.submit, kind: .question, screen: s) == [.down, .down, .down, .down, .enter])
  #expect(PromptKeys.keys(.option(5), kind: .question, screen: s) == Array(repeating: PromptKey.down, count: 5) + [.enter])
  #expect(PromptKeys.keys(.note("x"), kind: .question, screen: s) == Array(repeating: PromptKey.down, count: 3) + [.text("x"), .enter])
  // from the option after Submit, back up to Submit and to the option before it
  let low = screen(labels, selected: 4, checked: false, submitAfter: 3)
  #expect(PromptKeys.keys(.submit, kind: .question, screen: low) == [.up, .enter])
  #expect(PromptKeys.keys(.toggle(4), kind: .question, screen: low) == [.up, .up, PromptKeys.toggleKey])
}

@Test func denyIsTheNoOption() {
  #expect(PromptKeys.denyNumber(screen(["Yes", "Yes, always", "Yes, auto mode", "No"])) == 4)
  #expect(PromptKeys.denyNumber(screen(["red", "green"])) == nil)
}

@Test func aChangedDialogIsNotTheSame() {
  let a = screen(["Yes", "No"])
  #expect(PromptKeys.sameDialog(a, screen(["Yes", "No"], selected: 1)))   // only the selection moved
  #expect(!PromptKeys.sameDialog(a, screen(["Yes", "No"], question: "Other?")))
  #expect(!PromptKeys.sameDialog(a, screen(["Yes", "Yes, always", "No"])))
}

@Test func realCapturesGiveKeys() throws {
  let bash = try #require(PromptScreen.parse(try fixture("permission-bash")))
  let deny = try #require(PromptKeys.denyNumber(bash))
  #expect(PromptKeys.keys(.option(deny), kind: .permission, screen: bash) != nil)
  let single = try #require(PromptScreen.parse(try fixture("question-single")))
  #expect(PromptKeys.keys(.note("teal"), kind: .question, screen: single) == [.down, .down, .down, .text("teal"), .enter])
  let plan = try #require(PromptScreen.parse(try fixture("plan")))
  #expect(PromptKeys.keys(.note("smaller"), kind: .plan, screen: plan) == [.down, .down, .enter, .text("smaller"), .enter])
  let multi = try #require(PromptScreen.parse(try fixture("question-multiselect")))
  #expect(PromptKeys.keys(.submit, kind: .question, screen: multi) != nil)
  let review = try #require(PromptScreen.parse(try fixture("question-multi-submit")))
  #expect(PromptKeys.keys(.submit, kind: .question, screen: review) == [.enter])
}
