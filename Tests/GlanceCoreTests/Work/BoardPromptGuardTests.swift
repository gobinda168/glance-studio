import Foundation
import Testing
@testable import GlanceCore

private func fixture(_ name: String) throws -> String {
  let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/prompts/\(name).txt")
  return try String(contentsOf: url, encoding: .utf8)
}

/// A Bash dialog in Claude Code's real layout (Fixtures/prompts/permission-bash.txt), every one asking the same question.
private func bashText(_ command: String, options: [String] = ["Yes", "Yes, and don't ask again for this command", "No"]) -> String {
  let rule = String(repeating: "─", count: 60), dash = String(repeating: "╌", count: 60)
  let rows = options.enumerated().map { index, label in index == 0 ? " ❯ 1. \(label)" : "   \(index + 1). \(label)" }
  return ([rule, " Bash command", " Run something", dash, " \(command)", dash, " Do you want to proceed?"] + rows
    + ["", " Esc to cancel · Tab to amend"]).joined(separator: "\n")
}

private func bashScreen(_ command: String) throws -> DialogScreen { try #require(PromptScreen.parse(bashText(command))) }

private let session = "11111111-1111-1111-1111-111111111111"
private let otherSession = "22222222-2222-2222-2222-222222222222"
private let surface = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

private func transcript(_ id: String) -> String { "/Users/me/.claude/projects/-Users-me-app/\(id).jsonl" }

private func prompt(_ call: ToolCall, _ screen: DialogScreen, transcript file: String? = transcript(session),
                    on surface: UUID = surface) -> PendingPrompt {
  PendingPrompt(surface: surface.uuidString, cwd: "/Users/me/app", call: call, screen: screen, created: .distantPast,
                transcript: file)
}

private func bash(_ command: String, id: String = "toolu_1") -> ToolCall {
  ToolCall(id: id, name: "Bash", input: .object(["command": .string(command)]))
}

private func editCall(id: String = "toolu_1", file: String = "/Users/me/app/notes.txt") -> ToolCall {
  ToolCall(id: id, name: "Edit", input: .object(["file_path": .string(file), "old_string": .string("hello"),
                                                 "new_string": .string("goodbye")]))
}

@Suite struct BoardPromptGuardTests {
  // MARK: Click time

  @Test func theSamePromptStillUpIsAnswered() throws {
    let shown = prompt(bash("echo a"), try bashScreen("echo a"))
    #expect(BoardPromptGuard.refusal(shown: shown, session: session, linked: session, live: shown, screen: shown.screen) == nil)
  }

  @Test func theSameQuestionWithADifferentCommandRefuses() throws {
    let shown = prompt(bash("echo a"), try bashScreen("echo a"))
    let next = prompt(bash("rm -rf build", id: "toolu_2"), try bashScreen("rm -rf build"))
    // Every Bash dialog reads the same: the old check by question and labels passes.
    #expect(PromptKeys.sameDialog(shown.screen, next.screen))
    #expect(BoardPromptGuard.refusal(shown: shown, session: session, linked: session, live: next, screen: next.screen) == .callChanged)
  }

  @Test func theBookNotCaughtUpStillRefusesWhatTheScreenShowsNow() throws {
    let shown = prompt(bash("echo a"), try bashScreen("echo a"))
    // The book still holds the old call; the screen has moved on.
    #expect(BoardPromptGuard.refusal(shown: shown, session: session, linked: session, live: shown,
                                     screen: try bashScreen("rm -rf build")) == .screenChanged)
  }

  @Test func theSameCallIDWithADifferentInputRefuses() throws {
    let shown = prompt(bash("echo a"), try bashScreen("echo a"))
    let live = prompt(bash("rm -rf build"), try bashScreen("echo a"))
    #expect(BoardPromptGuard.refusal(shown: shown, session: session, linked: session, live: live, screen: shown.screen) == .callChanged)
  }

  @Test func aClearedOrResumedSessionRefuses() throws {
    let shown = prompt(bash("echo a"), try bashScreen("echo a"))
    #expect(BoardPromptGuard.refusal(shown: shown, session: session, linked: otherSession, live: shown, screen: shown.screen) == .sessionChanged)
    #expect(BoardPromptGuard.refusal(shown: shown, session: session, linked: nil, live: shown, screen: shown.screen) == .sessionChanged)
  }

  @Test func aMissingCallIDRefuses() throws {
    let shown = prompt(bash("echo a", id: ""), try bashScreen("echo a"))
    #expect(BoardPromptGuard.refusal(shown: shown, session: session, linked: session, live: shown, screen: shown.screen) == .noCall)
  }

  @Test func aPromptThatLeftRefuses() throws {
    let shown = prompt(bash("echo a"), try bashScreen("echo a"))
    #expect(BoardPromptGuard.refusal(shown: shown, session: session, linked: session, live: nil, screen: shown.screen) == .promptGone)
  }

  @Test func aScreenThatCantBeReadRefuses() throws {
    let shown = prompt(bash("echo a"), try bashScreen("echo a"))
    #expect(BoardPromptGuard.refusal(shown: shown, session: session, linked: session, live: shown, screen: nil) == .screenUnread)
  }

  @Test func changedOptionsOrScopeRefuse() throws {
    let shown = prompt(bash("echo a"), try bashScreen("echo a"))
    let scoped = try #require(PromptScreen.parse(bashText("echo a", options: ["Yes", "Yes, and don't ask again for anything", "No"])))
    #expect(BoardPromptGuard.refusal(shown: shown, session: session, linked: session, live: shown, screen: scoped) == .screenChanged)
  }

  @Test func onlyTheSelectionMovingStillAnswers() throws {
    let shown = prompt(bash("echo a"), try bashScreen("echo a"))
    let moved = DialogScreen(question: shown.screen.question, detail: shown.screen.detail, options: shown.screen.options,
                             selected: 2, detailIsWhole: true, kind: shown.screen.kind)
    #expect(BoardPromptGuard.refusal(shown: shown, session: session, linked: session, live: shown, screen: moved) == nil)
  }

  @Test func anotherSessionsCallInTheSameFolderRefuses() throws {
    // The book finds a split's call by folder: with two sessions there it can hold the other session's.
    let shown = prompt(bash("echo a"), try bashScreen("echo a"), transcript: transcript(otherSession))
    #expect(BoardPromptGuard.refusal(shown: shown, session: session, linked: session, live: shown, screen: shown.screen) == .notReadable)
  }

  // MARK: What the card offers

  @Test func aCommandOnScreenGetsButtons() throws {
    #expect(BoardPromptGuard.offersAnswers(prompt(bash("echo a"), try bashScreen("echo a")), session: session))
  }

  @Test func aWrappedCommandStillMatchesTheScreen() throws {
    let long = String(repeating: "abcdef ", count: 30).trimmingCharacters(in: .whitespaces)
    let wrapped = stride(from: 0, to: long.count, by: 50).map { start -> String in
      let from = long.index(long.startIndex, offsetBy: start)
      return String(long[from..<(long.index(from, offsetBy: 50, limitedBy: long.endIndex) ?? long.endIndex)])
    }.joined(separator: "\n   ")
    #expect(BoardPromptGuard.offersAnswers(prompt(bash(long), try bashScreen(wrapped)), session: session))
  }

  @Test func aCallThatIsntTheOneOnScreenGetsNoButtons() throws {
    // Two calls waiting in one folder, and the book took the other one.
    #expect(!BoardPromptGuard.offersAnswers(prompt(bash("rm -rf build"), try bashScreen("echo a")), session: session))
    #expect(!BoardPromptGuard.offersAnswers(prompt(ToolCall(id: "toolu_1", name: "Bash", input: .object([:])), try bashScreen("echo a")), session: session))
  }

  @Test func anEditOnScreenGetsButtonsAndAnotherFileOrChangeDoesNot() throws {
    let screen = try #require(PromptScreen.parse(try fixture("permission-edit")))
    #expect(BoardPromptGuard.offersAnswers(prompt(editCall(), screen), session: session))
    #expect(!BoardPromptGuard.offersAnswers(prompt(editCall(file: "/Users/me/app/other.txt"), screen), session: session))
    let other = ToolCall(id: "toolu_1", name: "Edit", input: .object(["file_path": .string("/Users/me/app/notes.txt"),
                                                                      "old_string": .string("hello"), "new_string": .string("farewell")]))
    #expect(!BoardPromptGuard.offersAnswers(prompt(other, screen), session: session))
  }

  @Test func aToolWithoutADetailToShowGetsNoButtons() throws {
    let bare = try #require(PromptScreen.parse(([String(repeating: "─", count: 60), " Do you want to proceed?", " ❯ 1. Yes", "   2. No", "",
                                                 " Esc to cancel"]).joined(separator: "\n")))
    #expect(bare.detail.isEmpty)
    #expect(!BoardPromptGuard.offersAnswers(prompt(ToolCall(id: "t", name: "WebFetch", input: .object([:])), bare), session: session))
  }

  @Test func anotherToolShowsTheScreensOwnTextSoItIsOffered() throws {
    let screen = try bashScreen("https://example.com")
    #expect(BoardPromptGuard.offersAnswers(prompt(ToolCall(id: "t", name: "WebFetch", input: .object([:])), screen), session: session))
  }

  @Test func aDetailCutShortGetsNoButtons() throws {
    // More lines than the parser keeps: what's shown would start part way through the command.
    let long = (1...14).map { "echo \($0)" }.joined(separator: "\n ")
    let cut = try bashScreen(long)
    #expect(!cut.detailIsWhole)
    #expect(!BoardPromptGuard.offersAnswers(prompt(bash(long), cut), session: session))
    // The dialog's top is off screen: nothing marks where its detail starts.
    let top = bashText("echo a").components(separatedBy: "\n").dropFirst().joined(separator: "\n")
    let headless = try #require(PromptScreen.parse(top))
    #expect(!headless.detailIsWhole)
    #expect(!BoardPromptGuard.offersAnswers(prompt(ToolCall(id: "t", name: "WebFetch", input: .object([:])), headless), session: session))
  }

  @Test func aPlanIsNeverAnsweredOnACard() throws {
    let screen = try #require(PromptScreen.parse(try fixture("plan")))
    let call = ToolCall(id: "t", name: "ExitPlanMode", input: .object(["plan": .string("Add world")]))
    #expect(!BoardPromptGuard.offersAnswers(prompt(call, screen), session: session))
  }

  @Test func aQuestionsOwnWordsAreItsDetail() throws {
    let call = ask(["Which colour?"])
    let plain = DialogScreen(question: "Which colour?", detail: [], options: [
      PromptOption(number: 1, label: "red", note: nil, checked: nil),
      PromptOption(number: 2, label: "green", note: nil, checked: nil),
    ], selected: 0, kind: .question)
    #expect(BoardPromptGuard.offersAnswers(prompt(call, plain), session: session))
    let unsaid = DialogScreen(question: nil, detail: [], options: plain.options, selected: 0, kind: .question)
    #expect(!BoardPromptGuard.offersAnswers(prompt(call, unsaid), session: session))
  }

  @Test func menusTheButtonsCantGiveGetNoButtons() throws {
    let call = ToolCall(id: "t", name: "AskUserQuestion", input: .object([:]))
    let ticks = try #require(PromptScreen.parse(try fixture("question-multiselect")))
    #expect(!BoardPromptGuard.offersAnswers(prompt(call, ticks), session: session))
    let five = try #require(PromptScreen.parse(bashText("echo a", options: ["Yes", "Yes, for now", "Yes, always", "Auto", "No"])))
    #expect(!BoardPromptGuard.offersAnswers(prompt(bash("echo a"), five), session: session))
    let none = DialogScreen(question: "Why?", detail: ["x"], options: [], selected: 0, detailIsWhole: true)
    #expect(!BoardPromptGuard.offersAnswers(prompt(call, none), session: session))
  }

  @Test func fourOptionsGetButtons() throws {
    // Claude Code's Bash dialog with its "switch to auto mode" option, as captured.
    let four = try #require(PromptScreen.parse(try fixture("permission-bash")))
    #expect(four.options.count == 4)
    #expect(BoardPromptGuard.offersAnswers(prompt(bash("echo glance-probe > probe.txt"), four), session: session))
  }

  @Test func aPromptWithoutATranscriptOrFromASubagentGetsNoButtons() throws {
    #expect(!BoardPromptGuard.offersAnswers(prompt(bash("echo a"), try bashScreen("echo a"), transcript: nil), session: session))
    #expect(!BoardPromptGuard.offersAnswers(prompt(bash("echo a"), try bashScreen("echo a"),
                                                   transcript: "/Users/me/.claude/projects/x/\(session)/subagents/agent-1.jsonl"), session: session))
  }

  // MARK: The dialog on screen decides, not the book's call

  private func ask(_ questions: [String]) -> ToolCall {
    ToolCall(id: "t", name: "AskUserQuestion", input: .object(["questions": .array(questions.map { .object(["question": .string($0)]) })]))
  }

  @Test func aQuestionOnScreenGetsButtons() throws {
    let screen = try #require(PromptScreen.parse(try fixture("question-multi-1")))
    #expect(screen.kind == .question)
    #expect(BoardPromptGuard.offersAnswers(prompt(ask(["Which color?", "Which size?"]), screen), session: session))
  }

  @Test func aQuestionInTheBookGivesNoButtonsToACutBashDialog() throws {
    // [Bash, AskUserQuestion] in one message: the book picks the question while the Bash dialog is up.
    let cut = try bashScreen((1...14).map { "echo \($0)" }.joined(separator: "\n "))
    #expect(cut.kind == .permission && !cut.detailIsWhole)
    #expect(!BoardPromptGuard.offersAnswers(prompt(ask(["Which color?"]), cut), session: session))
  }

  @Test func aQuestionInTheBookGivesNoButtonsToAnyOtherDialog() throws {
    let whole = try bashScreen("echo a")
    #expect(!BoardPromptGuard.offersAnswers(prompt(ask(["Which color?"]), whole), session: session))
    let plan = try #require(PromptScreen.parse(try fixture("plan")))
    #expect(plan.kind == .plan)
    #expect(!BoardPromptGuard.offersAnswers(prompt(ask(["Which color?"]), plan), session: session))
  }

  @Test func aQuestionMustBeOneTheCallAsks() throws {
    let screen = try #require(PromptScreen.parse(try fixture("question-multi-1")))
    #expect(!BoardPromptGuard.offersAnswers(prompt(ask(["Which database?"]), screen), session: session))
  }

  @Test func aPlanOrOtherCallInTheBookDoesntMakeAQuestionAnswerable() throws {
    let screen = try #require(PromptScreen.parse(try fixture("question-multi-1")))
    #expect(!BoardPromptGuard.offersAnswers(prompt(bash("echo a"), screen), session: session))
  }

  @Test func aDialogWhoseKeyHintsSayNothingKnownGetsNoButtons() throws {
    // The answers' review screen has no key hints at all.
    let review = try #require(PromptScreen.parse(try fixture("question-multi-submit")))
    #expect(review.kind == nil)
    #expect(!BoardPromptGuard.offersAnswers(prompt(ask(["Which color?"]), review), session: session))
  }

  @Test func theDialogsKindMovingRefusesAtTheClick() throws {
    let shown = prompt(bash("echo a"), try bashScreen("echo a"))
    let other = DialogScreen(question: shown.screen.question, detail: shown.screen.detail, options: shown.screen.options,
                             selected: 0, detailIsWhole: true, kind: .question)
    #expect(BoardPromptGuard.refusal(shown: shown, session: session, linked: session, live: shown, screen: other) == .screenChanged)
  }

  @Test func aSolidRuleInsideTheFrameIsntTheDialogsTop() throws {
    // A notebook cell holding a line of rule: the detail would stop there and call itself whole.
    let rule = String(repeating: "─", count: 60), dash = String(repeating: "╌", count: 60)
    let text = [rule, " Edit notebook", dash, " rm -rf build", rule, " print('hi')", dash, " Do you want to proceed?", " ❯ 1. Yes", "   2. No", "",
                " Esc to cancel · Tab to amend"].joined(separator: "\n")
    let screen = try #require(PromptScreen.parse(text))
    #expect(!screen.detailIsWhole)
    #expect(!BoardPromptGuard.offersAnswers(prompt(ToolCall(id: "t", name: "NotebookEdit", input: .object([:])), screen), session: session))
  }

  // MARK: Enter goes only on the row it means

  /// The dialog as it reads with the highlight on `row`: nothing but the selection differs.
  private func on(_ row: Int, _ screen: DialogScreen) -> DialogScreen {
    DialogScreen(question: screen.question, detail: screen.detail, options: screen.options, selected: row,
                 submitAfter: screen.submitAfter, detailIsWhole: screen.detailIsWhole, kind: screen.kind)
  }

  private func gate(_ answer: PromptAnswer, _ shown: PendingPrompt, _ screen: DialogScreen?, waited: TimeInterval = 0,
                    live: PendingPrompt? = nil) -> BoardPromptGuard.EnterGate {
    BoardPromptGuard.enterGate(answer, shown: shown, session: session, linked: session, live: live ?? shown, screen: screen, waited: waited)
  }

  /// Asks as Enter does, a read every `enterRetry`, until it stops waiting. `screen` is what each read shows at that moment.
  private func asked(_ answer: PromptAnswer, _ shown: PendingPrompt, screen: (TimeInterval) -> DialogScreen?) -> (BoardPromptGuard.EnterGate, reads: Int) {
    var reads = 0
    while reads < 1000 {
      let waited = Double(reads) * BoardPromptGuard.enterRetry
      reads += 1
      let result = gate(answer, shown, screen(waited), waited: waited)
      if result != .wait { return (result, reads) }
    }
    return (.wait, reads)
  }

  @Test func theRowItMeansGetsItsEnter() throws {
    let shown = prompt(bash("echo a"), try bashScreen("echo a"))
    #expect(gate(.option(1), shown, shown.screen) == .press)
    #expect(gate(.option(3), shown, on(2, shown.screen)) == .press)
  }

  @Test func aLostArrowRefusesAndNoEnterGoes() throws {
    // No, two arrows down from Yes, one lost: Enter would land on "don't ask again". Row 1 is Yes, so a lost arrow lands
    // nearer to yes, the wrong way round.
    let shown = prompt(bash("echo a"), try bashScreen("echo a"))
    let (result, reads) = asked(.option(3), shown) { _ in on(1, shown.screen) }
    #expect(result == .refuse(.wrongRow))
    // It read every 50 ms for the half second first.
    #expect(reads == 11)
    #expect(BoardPromptGuard.enterRetry == 0.05 && BoardPromptGuard.enterPatience == 0.5)
  }

  @Test func aRedrawThatTakesAMomentStillGoes() throws {
    let shown = prompt(bash("echo a"), try bashScreen("echo a"))
    let (result, reads) = asked(.option(3), shown) { waited in on(waited < 0.4 ? 0 : 2, shown.screen) }
    #expect(result == .press)
    #expect(reads == 9)
  }

  @Test func theLastReadOfTheWaitStillCounts() throws {
    let shown = prompt(bash("echo a"), try bashScreen("echo a"))
    // The row is what decides; a read that comes late, past a busy main thread, is as good as any.
    #expect(gate(.option(3), shown, on(2, shown.screen), waited: 5) == .press)
    #expect(gate(.option(3), shown, on(1, shown.screen), waited: 0.49) == .wait)
    #expect(gate(.option(3), shown, on(1, shown.screen), waited: 0.5) == .refuse(.wrongRow))
  }

  @Test func theUserMovingTheHighlightOffTheRowRefuses() throws {
    let shown = prompt(bash("echo a"), try bashScreen("echo a"))
    // Asked for No, and the highlight went back to Yes in the tab.
    let (result, _) = asked(.option(3), shown) { waited in on(waited < 0.1 ? 1 : 0, shown.screen) }
    #expect(result == .refuse(.wrongRow))
  }

  @Test func aDialogThatChangesWhileWaitingRefusesAtOnce() throws {
    let shown = prompt(bash("echo a"), try bashScreen("echo a"))
    #expect(gate(.option(3), shown, try bashScreen("rm -rf build")) == .refuse(.screenChanged))
    #expect(gate(.option(3), shown, nil) == .refuse(.screenUnread))
    let next = prompt(bash("rm -rf build", id: "toolu_2"), try bashScreen("echo a"))
    #expect(gate(.option(3), shown, shown.screen, live: next) == .refuse(.callChanged))
  }

  @Test func aRowThatCantBeToldRefuses() throws {
    let shown = prompt(bash("echo a"), try bashScreen("echo a"))
    #expect(gate(.option(9), shown, shown.screen) == .refuse(.wrongRow))
    // A card sends only options: ticks, Submit and typed notes have no row to compare.
    #expect(gate(.toggle(1), shown, shown.screen) == .refuse(.wrongRow))
    #expect(gate(.submit, shown, shown.screen) == .refuse(.wrongRow))
    #expect(gate(.note("no"), shown, shown.screen) == .refuse(.wrongRow))
  }

  @Test func theRowComesFromTheOptionsNumberAsTheKeysDo() throws {
    // Claude Code's Bash dialog as captured: the keys for option 3 arrive at the index the gate asks for.
    let four = try #require(PromptScreen.parse(try fixture("permission-bash")))
    let shown = prompt(bash("echo glance-probe > probe.txt"), four)
    #expect(PromptKeys.keys(.option(3), kind: .permission, screen: four) == [.down, .down, .enter])
    #expect(gate(.option(3), shown, four) == .wait)
    #expect(gate(.option(3), shown, on(2, four)) == .press)
  }

  // MARK: Looking a prompt up

  @Test func aCardsPromptGoesBySurfaceAndSession() throws {
    let waiting = prompt(bash("echo a"), try bashScreen("echo a"))
    let elsewhere = prompt(bash("echo b"), try bashScreen("echo b"), on: UUID())
    #expect(BoardPromptGuard.prompt(in: [elsewhere, waiting], surface: surface, session: session, linked: session) == waiting)
    // /clear'ed: the split runs another session now, so its prompt isn't this card's.
    #expect(BoardPromptGuard.prompt(in: [waiting], surface: surface, session: session, linked: otherSession) == nil)
    #expect(BoardPromptGuard.prompt(in: [waiting], surface: surface, session: session, linked: nil) == nil)
    #expect(BoardPromptGuard.prompt(in: [elsewhere], surface: surface, session: session, linked: session) == nil)
  }
}
