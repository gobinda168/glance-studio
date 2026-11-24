import Foundation
import Testing
@testable import GlanceCore

@Suite struct BoardKeysTests {
  func card(_ id: String, _ state: BoardState) -> BoardCard {
    BoardCard(id: id, title: id, project: "p", place: .external("x"), state: state, pill: .inProgress, activity: .distantPast)
  }
  // Board order: wait1, wait2 (Needs you), run (Working), idle (Done).
  var cards: [BoardCard] {
    [card("idle", .idle(since: nil)), card("run", .thinking), card("wait1", .waiting(title: "?")), card("wait2", .waiting(title: "?"))]
  }

  @Test func jAndKMoveThroughTheLanesAndStopAtTheEnds() {
    #expect(BoardKeys.selection(for: .next, current: nil, cards: cards) == "wait1")
    #expect(BoardKeys.selection(for: .next, current: "wait2", cards: cards) == "run")
    #expect(BoardKeys.selection(for: .next, current: "idle", cards: cards) == "idle")
    #expect(BoardKeys.selection(for: .previous, current: "wait1", cards: cards) == "wait1")
  }

  @Test func nCyclesThroughWhatNeedsTheUser() {
    #expect(BoardKeys.selection(for: .nextNeedingYou, current: nil, cards: cards) == "wait1")
    #expect(BoardKeys.selection(for: .nextNeedingYou, current: "wait1", cards: cards) == "wait2")
    #expect(BoardKeys.selection(for: .nextNeedingYou, current: "wait2", cards: cards) == "wait1")
    // Nothing needs the user: the selection stays.
    #expect(BoardKeys.selection(for: .nextNeedingYou, current: "run", cards: [card("run", .thinking)]) == "run")
  }

  @Test func aNumberGoesToItsLanesFirstCard() {
    #expect(BoardKeys.selection(for: .lane(1), current: nil, cards: cards) == "run")
    // An empty lane leaves the selection alone.
    #expect(BoardKeys.selection(for: .lane(2), current: "run", cards: cards) == "run")
    #expect(BoardKeys.selection(for: .lane(9), current: "run", cards: cards) == "run")
  }

  @Test func aSelectionThatLeftTheBoardStartsOver() {
    #expect(BoardKeys.selection(for: .next, current: "gone", cards: cards) == "wait1")
    #expect(BoardKeys.selection(for: .next, current: nil, cards: []) == nil)
  }

  // MARK: Whether the board has the keyboard

  func context(key: Bool = true, plain: Bool = true, focus: BoardKeys.Focus = .page, reply: Bool = false,
               fullKeyboardAccess: Bool = false) -> BoardKeys.Context {
    BoardKeys.Context(boardIsKey: key, plain: plain, focus: focus, replyOpen: reply, fullKeyboardAccess: fullKeyboardAccess)
  }

  @Test func theBoardsKeysWorkWhenTheBoardHasTheKeyboard() {
    #expect(BoardKeys.command(characters: "j", keyCode: 38, in: context()) == .move(.next))
    #expect(BoardKeys.command(characters: "k", keyCode: 40, in: context()) == .move(.previous))
    #expect(BoardKeys.command(characters: "n", keyCode: 45, in: context()) == .move(.nextNeedingYou))
    #expect(BoardKeys.command(characters: "1", keyCode: 18, in: context()) == .move(.lane(0)))
    #expect(BoardKeys.command(characters: "4", keyCode: 21, in: context()) == .move(.lane(3)))
    #expect(BoardKeys.command(characters: "r", keyCode: 15, in: context()) == .startReply)
    #expect(BoardKeys.command(characters: "\r", keyCode: 36, in: context()) == .open)
  }

  @Test func anythingElseIsLeftAlone() {
    #expect(BoardKeys.command(characters: "x", keyCode: 7, in: context()) == nil)
    #expect(BoardKeys.command(characters: "5", keyCode: 23, in: context()) == nil)
    #expect(BoardKeys.command(characters: "0", keyCode: 29, in: context()) == nil)
    #expect(BoardKeys.command(characters: "\u{1B}", keyCode: 53, in: context()) == nil)
    #expect(BoardKeys.command(characters: nil, keyCode: 7, in: context()) == nil)
  }

  @Test func withTheFocusElsewhereNoKeyIsTaken() {
    // A web view, a terminal surface, the Glance pane, a list or any other field: all of it is `elsewhere`.
    let elsewhere = context(focus: .elsewhere)
    for (characters, code): (String, UInt16) in [("j", 38), ("k", 40), ("n", 45), ("r", 15), ("1", 18), ("\r", 36), ("\u{1B}", 53)] {
      #expect(BoardKeys.command(characters: characters, keyCode: code, in: elsewhere) == nil)
      #expect(BoardKeys.command(characters: characters, keyCode: code, in: context(focus: .elsewhere, reply: true)) == nil)
    }
  }

  @Test func withAnotherWindowKeyOrAModifierNoKeyIsTaken() {
    #expect(BoardKeys.command(characters: "j", keyCode: 38, in: context(key: false)) == nil)
    #expect(BoardKeys.command(characters: "\r", keyCode: 36, in: context(key: false)) == nil)
    #expect(BoardKeys.command(characters: "j", keyCode: 38, in: context(plain: false)) == nil)
  }

  @Test func aFocusedControlKeepsItsReturn() {
    // With keyboard access on, Tab can put the focus on a SwiftUI button inside the page, and the responder doesn't show it.
    #expect(BoardKeys.command(characters: "\r", keyCode: 36, in: context(fullKeyboardAccess: true)) == nil)
    #expect(BoardKeys.command(characters: "j", keyCode: 38, in: context(fullKeyboardAccess: true)) == .move(.next))
  }

  @Test func whileTheReplyBoxTypesOnlyEscIsTheBoards() {
    let typing = context(focus: .replyBox, reply: true)
    for (characters, code): (String, UInt16) in [("j", 38), ("r", 15), ("1", 18), ("\r", 36)] {
      #expect(BoardKeys.command(characters: characters, keyCode: code, in: typing) == nil)
    }
    #expect(BoardKeys.command(characters: "\u{1B}", keyCode: 53, in: typing) == .closeReply)
  }

  @Test func theReplyBoxOpenButNotYetFocusedTakesOnlyEsc() {
    let opening = context(reply: true)
    #expect(BoardKeys.command(characters: "j", keyCode: 38, in: opening) == nil)
    #expect(BoardKeys.command(characters: "\r", keyCode: 36, in: opening) == nil)
    #expect(BoardKeys.command(characters: "\u{1B}", keyCode: 53, in: opening) == .closeReply)
  }

  @Test func noKeyAnswersAPrompt() {
    // 1-4 go to a lane on every card, waiting or not: a prompt is answered only by clicking what it shows.
    for digit in 1...4 {
      #expect(BoardKeys.command(characters: "\(digit)", keyCode: 18, in: context()) == .move(.lane(digit - 1)))
    }
  }
}
