import Foundation
import Testing
@testable import GlanceCore

private let dialog = """
────────────────────────────────────────
 Bash command
   ls
 Do you want to proceed?
 ❯ 1. Yes
   2. No
 Esc to cancel
"""
private let t0 = Date(timeIntervalSince1970: 1000)
private func bash(_ id: String) -> ToolEvent {
  ToolEvent(kind: .pending(ToolCall(id: id, name: "Bash", input: .object(["command": .string("ls")]))), cwd: "/app")
}

@Test func aPromptNeedsAWaitingCallAndADialog() {
  var book = PromptBook()
  let result1 = book.screen(surface: "S", cwd: "/app", text: dialog, now: t0)
  #expect(!result1)   // no waiting call yet
  book.tool(bash("t1"), file: "/f", now: t0)
  #expect(book.folders(now: t0) == ["/app"])
  let result2 = book.screen(surface: "S", cwd: "/app", text: dialog, now: t0)
  #expect(result2)
  #expect(book.prompts["S"]?.call.id == "t1")
  #expect(book.prompts["S"]?.kind == .permission)
  #expect(book.prompts["S"]?.project == "app")
}

@Test func slowToolWithoutDialogMakesNoPrompt() {
  var book = PromptBook()
  book.tool(bash("t1"), file: "/f", now: t0)
  let result = book.screen(surface: "S", cwd: "/app", text: "⏺ Running…\n  esc to interrupt", now: t0)
  #expect(!result)
  #expect(book.prompts.isEmpty)
}

@Test func aResultATurnOrAClosedSplitClearsIt() {
  var book = PromptBook()
  book.tool(bash("t1"), file: "/f", now: t0)
  _ = book.screen(surface: "S", cwd: "/app", text: dialog, now: t0)
  book.tool(ToolEvent(kind: .settled(id: "t1"), cwd: "/app"), file: "/f", now: t0)
  #expect(book.prompts.isEmpty && book.folders(now: t0).isEmpty)

  book.tool(bash("t2"), file: "/f", now: t0)
  _ = book.screen(surface: "S", cwd: "/app", text: dialog, now: t0)
  book.turn(file: "/f")
  #expect(book.prompts.isEmpty)

  book.tool(bash("t3"), file: "/f", now: t0)
  _ = book.screen(surface: "S", cwd: "/app", text: dialog, now: t0)
  let result = book.screen(surface: "S", cwd: nil, text: nil, now: t0)
  #expect(result)
  #expect(book.prompts.isEmpty)
}

@Test func theDialogLeavingTheScreenClearsIt() {
  var book = PromptBook()
  book.tool(bash("t1"), file: "/f", now: t0)
  _ = book.screen(surface: "S", cwd: "/app", text: dialog, now: t0)
  let result = book.screen(surface: "S", cwd: "/app", text: "❯ \n  ? for shortcuts", now: t0)
  #expect(result)
  #expect(book.prompts.isEmpty)
}

@Test func theSameCallKeepsItsCreatedDate() {
  var book = PromptBook()
  book.tool(bash("t1"), file: "/f", now: t0)
  _ = book.screen(surface: "S", cwd: "/app", text: dialog, now: t0)
  _ = book.screen(surface: "S", cwd: "/app", text: dialog.replacingOccurrences(of: "❯ 1. Yes\n   2. No", with: "  1. Yes\n ❯ 2. No"),
              now: t0.addingTimeInterval(5))
  #expect(book.prompts["S"]?.created == t0)
  #expect(book.prompts["S"]?.screen.selected == 1)
}

@Test func twoSplitsInOneFolderTakeDifferentCalls() {
  var book = PromptBook()
  book.tool(bash("t1"), file: "/f1", now: t0)
  book.tool(bash("t2"), file: "/f2", now: t0)
  _ = book.screen(surface: "A", cwd: "/app", text: dialog, now: t0)
  _ = book.screen(surface: "B", cwd: "/app", text: dialog, now: t0)
  #expect(Set([book.prompts["A"]?.call.id, book.prompts["B"]?.call.id]) == ["t1", "t2"])
}

@Test func oldWaitingCallsExpire() {
  var book = PromptBook()
  book.tool(bash("t1"), file: "/f", now: t0)
  book.expire(now: t0.addingTimeInterval(PromptBook.maxWait + 1))
  #expect(book.folders(now: t0).isEmpty)
}

@Test func kindsComeFromTheTool() {
  #expect(PromptKind(tool: "AskUserQuestion") == .question)
  #expect(PromptKind(tool: "ExitPlanMode") == .plan)
  #expect(PromptKind(tool: "Edit") == .permission)
}
