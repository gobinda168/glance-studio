import Foundation
import Testing
@testable import GlanceCore

private func fixture(_ name: String) throws -> String {
  let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Fixtures/prompts/\(name).txt")
  return try String(contentsOf: url, encoding: .utf8)
}

@Test func bashPermissionHasItsOptionsAndYesSelected() throws {
  let screen = try #require(PromptScreen.parse(try fixture("permission-bash")))
  #expect(screen.question == "Do you want to proceed?")
  #expect(screen.options.first?.label == "Yes")
  #expect(screen.options.last?.label.hasPrefix("No") == true)
  #expect(screen.selected == 0)
  #expect(screen.options.map(\.number) == Array(1...screen.options.count))
  #expect(screen.detail.contains { $0.contains("echo glance-probe > probe.txt") })
}

@Test func movingDownMovesTheSelection() throws {
  let first = try #require(PromptScreen.parse(try fixture("question-single")))
  let down = try #require(PromptScreen.parse(try fixture("question-single-down")))
  #expect(first.labels == down.labels)
  #expect(down.selected == first.selected + 1)
}

@Test func aQuestionHasItsTextOptionsAndFreeTextEntry() throws {
  let screen = try #require(PromptScreen.parse(try fixture("question-single")))
  #expect(screen.question?.contains("color") == true)
  #expect(Array(screen.labels.prefix(3)).map { $0.lowercased() } == ["red", "green", "blue"])
  #expect(screen.freeTextIndex != nil)
}

@Test func multiSelectOptionsHaveBoxes() throws {
  let screen = try #require(PromptScreen.parse(try fixture("question-multiselect")))
  #expect(screen.options.prefix(3).allSatisfy { $0.checked == false })
}

@Test func editAndPlanAreDialogs() throws {
  #expect(PromptScreen.parse(try fixture("permission-edit")) != nil)
  let plan = try #require(PromptScreen.parse(try fixture("plan")))
  #expect(plan.labels.contains { $0.lowercased().contains("tell claude what to change") })
}

@Test func idleWorkingAndAfterEscAreNotDialogs() throws {
  #expect(PromptScreen.parse(try fixture("idle")) == nil)
  #expect(PromptScreen.parse(try fixture("working")) == nil)
  #expect(PromptScreen.parse(try fixture("permission-bash-after-esc")) == nil)
}

@Test func numberedListInAReplyIsNotADialog() {
  let reply = """
  ⏺ Here's the plan:
    1. Install the dependencies
    2. Run the tests
    3. Ship it

  ❯ 
    ? for shortcuts
  """
  #expect(PromptScreen.parse(reply) == nil)
}

@Test func syntheticDialogParses() throws {
  let text = """
  ────────────────────────────────────────
   Bash command
     rm -rf build
   Do you want to proceed?
   ❯ 1. Yes
     2. Yes, and don't ask again for rm commands in
        /Users/me/app
     3. No
   Esc to cancel · Tab to amend
  """
  let screen = try #require(PromptScreen.parse(text))
  #expect(screen.labels == ["Yes", "Yes, and don't ask again for rm commands in", "No"])
  #expect(screen.options[1].note == "/Users/me/app")
  #expect(screen.detail == ["Bash command", "rm -rf build"])
  #expect(screen.selected == 0)
}

@Test func reviewScreenWithoutFooterParses() throws {
  let screen = try #require(PromptScreen.parse(try fixture("question-multi-submit")))
  #expect(screen.labels == ["Submit answers", "Cancel"])
  #expect(screen.selected == 0)
}

@Test func multiSelectSubmitRowIsNotANote() throws {
  let screen = try #require(PromptScreen.parse(try fixture("question-multiselect")))
  let typeIndex = try #require(screen.options.firstIndex { $0.label.lowercased().hasPrefix("type something") })
  #expect(screen.submitAfter == typeIndex)
  #expect(screen.options[typeIndex].note == nil)
  let ticked = try #require(PromptScreen.parse(try fixture("question-multiselect-space")))
  #expect(ticked.options[0].checked == true)
}

@Test func planHasItsQuestion() throws {
  let plan = try #require(PromptScreen.parse(try fixture("plan")))
  #expect(plan.question?.contains("ready to execute") == true)
  #expect(plan.selected == 0)
}
