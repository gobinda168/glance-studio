import Foundation
import Testing
@testable import GlanceCore

private func fixture(_ name: String) throws -> String {
  let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/prompts/\(name).txt")
  return try String(contentsOf: url, encoding: .utf8)
}

private let session = "11111111-1111-1111-1111-111111111111"
private let otherSession = "22222222-2222-2222-2222-222222222222"
private let one = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
private let two = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

@Suite struct BoardReplyTests {
  func split(_ surface: UUID = one, linked: String? = session, claude: Bool = true, prompt: Bool = false,
             screen: String? = nil, bracketed: Bool? = true) throws -> BoardReply.Split {
    BoardReply.Split(surface: surface, linkedSession: linked, runsClaude: claude, hasPrompt: prompt,
                     screen: try screen ?? fixture("idle"), bracketedPaste: bracketed)
  }

  // MARK: The text

  @Test func newlinesBecomeLF() {
    #expect(BoardReply.sanitized("one\r\ntwo\rthree\nfour") == "one\ntwo\nthree\nfour")
    #expect(BoardReply.sanitized("one\u{2028}two\u{2029}three\u{85}four") == "one\ntwo\nthree\nfour")
  }

  @Test func escapeSequencesGoWhole() {
    #expect(BoardReply.sanitized("a\u{1B}[31mb\u{1B}[0mc") == "abc")
    #expect(BoardReply.sanitized("a\u{1B}]0;title\u{07}b") == "ab")
    #expect(BoardReply.sanitized("a\u{1B}]0;title\u{1B}\\b") == "ab")
    #expect(BoardReply.sanitized("a\u{1B}cb") == "ab")
    #expect(BoardReply.sanitized("ab\u{1B}") == "ab")
  }

  @Test func thePasteEndMarkerCantBreakOut() {
    #expect(BoardReply.sanitized("safe\u{1B}[201~\nrm -rf /\n") == "safe\nrm -rf /")
    #expect(!BoardReply.sanitized("a\u{1B}[200~b\u{1B}[201~c").contains("\u{1B}"))
    #expect(BoardReply.sanitized("a\u{1B}[200~b\u{1B}[201~c") == "abc")
    // The eight-bit form of the same introducer.
    #expect(BoardReply.sanitized("a\u{9B}201~b") == "ab")
  }

  @Test func otherControlCharactersGo() {
    #expect(BoardReply.sanitized("a\u{03}b\u{04}c\u{15}d\u{00}e\u{08}f\u{7F}g\u{1A}h") == "abcdefgh")
    #expect(BoardReply.sanitized("a\tb") == "a b")
  }

  @Test func anUnendedStringSequenceDoesntTakeTheRestOfTheReply() {
    #expect(BoardReply.sanitized("keep\u{1B}]0;this too") == "keep0;this too")
    #expect(BoardReply.sanitized("keep\u{1B}Pthis") == "keepthis")
  }

  @Test func ordinaryTextIsLeftAlone() {
    #expect(BoardReply.sanitized("  fix the \"tests\" — ok? ✓ [201~ \n") == "fix the \"tests\" — ok? ✓ [201~")
    #expect(BoardReply.sanitized(" \r\n\u{1B}[0m ") == "")
  }

  // MARK: Where it may go

  @Test func aLiveLinkedClaudeAtItsInputTakesTheReply() throws {
    #expect(BoardReply.target(for: session, text: "hi", among: [try split()]) == one)
    #expect(BoardReply.target(for: session, text: "hi", among: [try split(screen: fixture("working"))]) == one)
  }

  @Test func aLinkThatNamesAnotherSessionRefuses() throws {
    #expect(BoardReply.target(for: session, text: "hi", among: [try split(linked: otherSession)]) == nil)
    #expect(BoardReply.target(for: session, text: "hi", among: [try split(linked: nil)]) == nil)
  }

  @Test func aShellRefuses() throws {
    #expect(BoardReply.target(for: session, text: "hi", among: [try split(claude: false)]) == nil)
    #expect(BoardReply.target(for: session, text: "hi", among: []) == nil)
  }

  @Test func aDialogOpenRefuses() throws {
    #expect(BoardReply.target(for: session, text: "hi", among: [try split(prompt: true)]) == nil)
    for name in ["permission-bash", "permission-edit", "plan", "question-single", "question-multiselect", "question-multi-submit"] {
      #expect(BoardReply.target(for: session, text: "hi", among: [try split(screen: fixture(name))]) == nil, "\(name)")
    }
  }

  @Test func aScreenThatCantBeReadRefuses() {
    let unread = BoardReply.Split(surface: one, linkedSession: session, runsClaude: true, hasPrompt: false, screen: nil, bracketedPaste: true)
    #expect(BoardReply.target(for: session, text: "hi", among: [unread]) == nil)
  }

  @Test func aScreenThatIsntClaudesInputRefuses() throws {
    // A picker or a screen Glance can't place: no line for the reply to go on.
    #expect(BoardReply.target(for: session, text: "hi", among: [try split(screen: "Welcome back\n\nSelect a session:\n  one\n  two\n")]) == nil)
  }

  @Test func ofTwoTabsTheWaitingOneComesFirstAndRefuses() throws {
    // `BoardEntries.targets` gives the waiting split first: the reply never slips past it to the idle tab.
    #expect(BoardReply.target(for: session, text: "hi", among: [try split(one, prompt: true), try split(two)]) == nil)
    #expect(BoardReply.target(for: session, text: "hi", among: [try split(one, claude: false), try split(two)]) == two)
  }

  @Test func aSeveralLineReplyNeedsAFramedPaste() throws {
    // Without bracketed paste the terminal turns each LF into CR: the first line would submit on its own.
    #expect(BoardReply.target(for: session, text: "one\ntwo", among: [try split(bracketed: true)]) == one)
    #expect(BoardReply.target(for: session, text: "one\ntwo", among: [try split(bracketed: false)]) == nil)
    #expect(BoardReply.target(for: session, text: "one\ntwo", among: [try split(bracketed: nil)]) == nil)
    #expect(BoardReply.target(for: session, text: "one", among: [try split(bracketed: false)]) == one)
  }

  // MARK: The Return

  @Test func returnNeedsItAllStillTrue() throws {
    #expect(BoardReply.mayPressReturn(session: session, split: try split()))
    #expect(!BoardReply.mayPressReturn(session: session, split: try split(claude: false)))
    #expect(!BoardReply.mayPressReturn(session: session, split: try split(linked: otherSession)))
    #expect(!BoardReply.mayPressReturn(session: session, split: try split(prompt: true)))
    #expect(!BoardReply.mayPressReturn(session: session, split: try split(screen: fixture("permission-bash"))))
    #expect(!BoardReply.mayPressReturn(session: session, split: nil))
    let unread = BoardReply.Split(surface: one, linkedSession: session, runsClaude: true, hasPrompt: false, screen: nil, bracketedPaste: true)
    #expect(!BoardReply.mayPressReturn(session: session, split: unread))
  }

  // MARK: A Return follows only text Claude took

  /// Claude's input box in its real layout (Fixtures/prompts/idle.txt), holding `lines`.
  func box(_ lines: [String]) -> String {
    let rule = String(repeating: "─", count: 60)
    let input = lines.enumerated().map { $0 == 0 ? "❯\u{00A0}\($1)" : "  \($1)" }
    return (["  Some earlier output", rule] + input + [rule, "  ⏸ manual mode on"]).joined(separator: "\n")
  }

  @Test func theReplyOnTheInputLineGetsItsReturn() throws {
    #expect(BoardReply.returnGate(session: session, split: try split(screen: box(["hello there"])), text: "hello there") == .press)
    // Whatever the user had typed first, the paste lands at the cursor.
    #expect(BoardReply.returnGate(session: session, split: try split(screen: box(["so hello there"])), text: "hello there") == .press)
  }

  @Test func anOldInputBoxWithoutTheReplyGetsNoReturn() throws {
    // `claude -p` in front with the old frame on screen: the text sits in the tty queue, and nothing draws it.
    #expect(BoardReply.returnGate(session: session, split: try split(), text: "hello there") == .wait)
    #expect(BoardReply.returnGate(session: session, split: try split(screen: box([""])), text: "hello there") == .wait)
    #expect(BoardReply.returnGate(session: session, split: try split(screen: fixture("working")), text: "hello there") == .wait)
  }

  @Test func aShortReplyInTheBoxsHintIsntTheReply() throws {
    // The idle hint reads `Try "fix typecheck errors"`: a short reply is somewhere in almost any text.
    #expect(BoardReply.returnGate(session: session, split: try split(), text: "y") == .wait)
    #expect(BoardReply.returnGate(session: session, split: try split(), text: "fix") == .wait)
  }

  @Test func theSameWordsElsewhereOnScreenDontCount() throws {
    let screen = "  hello there\n" + box([""])
    #expect(BoardReply.returnGate(session: session, split: try split(screen: screen), text: "hello there") == .wait)
  }

  @Test func aWrappedReplyMatchesOnItsEnd() throws {
    let long = String(repeating: "word ", count: 60).trimmingCharacters(in: .whitespaces)
    let wrapped = stride(from: 0, to: long.count, by: 50).map { start -> String in
      let from = long.index(long.startIndex, offsetBy: start)
      return String(long[from..<(long.index(from, offsetBy: 50, limitedBy: long.endIndex) ?? long.endIndex)])
    }
    #expect(BoardReply.returnGate(session: session, split: try split(screen: box(wrapped)), text: long) == .press)
    // Its start alone was drawn: not established.
    #expect(BoardReply.returnGate(session: session, split: try split(screen: box(Array(wrapped.prefix(2)))), text: long + " and the end") == .wait)
  }

  @Test func aSeveralLineReplyMatchesAcrossItsLines() throws {
    #expect(BoardReply.returnGate(session: session, split: try split(screen: box(["one", "two"])), text: "one\ntwo") == .press)
  }

  @Test func claudesPastePlaceholderCountsOnlyForALongPaste() throws {
    let long = (1...40).map { "line \($0)" }.joined(separator: "\n")
    #expect(BoardReply.returnGate(session: session, split: try split(screen: box(["[Pasted text #1 +39 lines]"])), text: long) == .press)
    let wide = String(repeating: "x", count: 1000)
    #expect(BoardReply.returnGate(session: session, split: try split(screen: box(["[Pasted text #1]"])), text: wide) == .press)
    // A short reply is never collapsed, so a placeholder in the box is something else.
    #expect(BoardReply.returnGate(session: session, split: try split(screen: box(["[Pasted text #1 +39 lines]"])), text: "hello") == .wait)
  }

  @Test func anythingWrongBesidesTheTextHoldsAtOnce() throws {
    let drawn = box(["hello"])
    #expect(BoardReply.returnGate(session: session, split: try split(claude: false, screen: drawn), text: "hello") == .hold)
    #expect(BoardReply.returnGate(session: session, split: try split(linked: otherSession, screen: drawn), text: "hello") == .hold)
    #expect(BoardReply.returnGate(session: session, split: try split(prompt: true, screen: drawn), text: "hello") == .hold)
    #expect(BoardReply.returnGate(session: session, split: try split(screen: fixture("permission-bash")), text: "hello") == .hold)
    #expect(BoardReply.returnGate(session: session, split: nil, text: "hello") == .hold)
    // Nothing to match is nothing established.
    #expect(BoardReply.returnGate(session: session, split: try split(screen: drawn), text: " \n") == .hold)
  }

  // MARK: A call just made

  private func book(_ calls: (name: String, file: String, at: Date)...) -> [PromptBook.Waiting] {
    var book = PromptBook()
    for (index, call) in calls.enumerated() {
      let pending = ToolCall(id: "toolu_\(index)", name: call.name, input: .object([:]))
      book.tool(ToolEvent(kind: .pending(pending), cwd: "/Users/me/app"), file: call.file, now: call.at)
    }
    return book.waiting
  }

  private var mine: String { "/Users/me/.claude/projects/-Users-me-app/\(session).jsonl" }

  @Test func aCallUnderASecondOldCounts() {
    let now = Date()
    #expect(BoardReply.callJustStarted(waiting: book(("Bash", mine, now.addingTimeInterval(-0.5))), session: session, now: now))
    #expect(BoardReply.callJustStarted(waiting: book(("mcp__server__tool", mine, now)), session: session, now: now))
    #expect(!BoardReply.callJustStarted(waiting: book(("Bash", mine, now.addingTimeInterval(-1))), session: session, now: now))
    #expect(!BoardReply.callJustStarted(waiting: [], session: session, now: now))
  }

  @Test func aReadOnlyCallDoesntCount() {
    let now = Date()
    #expect(!BoardReply.callJustStarted(waiting: book(("Read", mine, now), ("Grep", mine, now)), session: session, now: now))
    #expect(BoardReply.callJustStarted(waiting: book(("Read", mine, now), ("Edit", mine, now)), session: session, now: now))
  }

  @Test func onlyThisSessionsCallsCountIncludingItsSubagents() {
    let now = Date()
    let other = "/Users/me/.claude/projects/-Users-me-app/\(otherSession).jsonl"
    #expect(!BoardReply.callJustStarted(waiting: book(("Bash", other, now)), session: session, now: now))
    // A subagent's dialog comes up in its parent's terminal.
    let subagent = "/Users/me/.claude/projects/-Users-me-app/\(session)/subagents/agent-1.jsonl"
    #expect(BoardReply.callJustStarted(waiting: book(("Bash", subagent, now)), session: session, now: now))
  }

  @Test func theReplyOnItsLineStillWaitsOutACallJustMade() throws {
    var starting = try split(screen: box(["hello there"]))
    starting.callJustStarted = true
    #expect(BoardReply.returnGate(session: session, split: starting, text: "hello there") == .wait)
    // It only ever waits: what would hold, holds, and once the call is older the same read presses.
    var wrong = starting
    wrong.runsClaude = false
    #expect(BoardReply.returnGate(session: session, split: wrong, text: "hello there") == .hold)
    starting.callJustStarted = false
    #expect(BoardReply.returnGate(session: session, split: starting, text: "hello there") == .press)
  }

  // MARK: A Return held back

  @Test func aRetryAfterAHeldReturnIsRefusedUntilTheTabIsOpened() {
    // The first paste may still be on the line: a second would double it, so the user finishes it in the tab.
    var held = BoardReply.HeldReplies()
    #expect(!held.isHeld(session))
    held.hold(session, on: two)
    #expect(held.isHeld(session))
    #expect(!held.isHeld(otherSession))
    // Opening goes to the tab the text is on, which needn't be the card's own.
    #expect(held.surface(of: session) == two)
    held.opened(otherSession)
    #expect(held.isHeld(session))
    held.opened(session)
    #expect(!held.isHeld(session))
  }

  // MARK: Claude's input line

  @Test func theInputLineIsFoundOnlyWhereClaudeIsAtIt() throws {
    for name in ["idle", "working", "permission-bash-after-esc"] {
      #expect(PromptScreen.atInput(try fixture(name)), "\(name)")
    }
    for name in ["permission-bash", "permission-edit", "plan", "question-single", "question-single-down", "question-multi-1",
                 "question-multi-2", "question-multi-submit", "question-multiselect", "question-multiselect-space"] {
      #expect(!PromptScreen.atInput(try fixture(name)), "\(name)")
    }
  }

  @Test func aPickerBetweenRulesIsntTheInputLine() {
    let rule = String(repeating: "─", count: 60)
    let picker = [rule, "❯ first session", "  second session", rule, " ↑/↓ to navigate · Esc to cancel"].joined(separator: "\n")
    #expect(!PromptScreen.atInput(picker))
    #expect(!PromptScreen.atInput(""))
    #expect(!PromptScreen.atInput("user@mac ~ % "))
  }
}
