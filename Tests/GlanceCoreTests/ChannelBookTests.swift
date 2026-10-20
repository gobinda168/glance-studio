import Foundation
import Testing
@testable import GlanceCore

@Suite struct ChannelBookTests {
  private let t0 = Date(timeIntervalSince1970: 1_000_000)
  private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

  private func book(channel: Bool = false) -> ChannelBook {
    var book = ChannelBook()
    book.open(.init(id: 1, label: "glance", projectDir: "/u/glance", surface: "S1", channel: channel, assistant: false,
                    now: t0))
    return book
  }

  @Test func aPlainNudgeNotifiesAndAnswersAtOnce() {
    var book = book()
    let (id, effects) = book.nudge(session: 1, callID: "c1", title: "Tests pass", body: nil, actions: [], wait: 300,
                                   now: t0)
    #expect(effects == [.notify(1, id: id, title: "Tests pass", body: nil),
                        .reply(1, callID: "c1", value: ["id": .string(id), "shown": true], isError: false)])
    #expect(book.cards.isEmpty)
  }

  @Test func aNudgeWithActionsWaitsForTheClick() {
    var book = book()
    let (id, effects) = book.nudge(session: 1, callID: "c1", title: "Deploy?", body: nil, actions: ["Ship", "Later"],
                                   wait: 300, now: t0)
    #expect(effects.isEmpty)
    #expect(book.active?.id == id)
    let answered = book.answer(id, .action("Ship"), via: .click)
    #expect(answered.first == .reply(1, callID: "c1", value: ["id": .string(id), "action": "Ship", "via": "click"],
                                     isError: false))
    #expect(book.cards.isEmpty)
  }

  @Test func anAskTimesOutToPendingAndTheCardStays() {
    var book = book()
    let (id, _) = book.ask(session: 1, callID: "c1", question: "Revert?", choices: ["Yes", "No"], allowText: true,
                           wait: 60, now: t0)
    #expect(book.tick(now: at(59)).isEmpty)
    #expect(book.tick(now: at(60)) == [.reply(1, callID: "c1", value: ChannelBook.pending(id), isError: false)])
    #expect(book.cards.first?.stoppedWaiting == true)
    #expect(book.cards.first?.waiter == nil)
  }

  @Test func aLateAnswerIsKeptForCheckAnswerWithoutAChannel() {
    var book = book()
    let (id, _) = book.ask(session: 1, callID: "c1", question: "Revert?", choices: [], allowText: true, wait: 1,
                           now: t0)
    _ = book.tick(now: at(2))
    let effects = book.answer(id, .text("fix forward"), via: .voice)
    #expect(effects.count == 1)   // only the Notifications item
    #expect(book.checkAnswer(session: 1, callID: "c2", id: id, wait: 0, now: at(3))
      == [.reply(1, callID: "c2", value: ["id": .string(id), "answer": "fix forward", "via": "voice"], isError: false)])
    // Collected once.
    #expect(book.checkAnswer(session: 1, callID: "c3", id: id, wait: 0, now: at(4)).first
      == .reply(1, callID: "c3", value: .string("No question or nudge with id \(id) is waiting."), isError: true))
  }

  @Test func aLateAnswerIsPushedWhenTheSessionHasAChannel() {
    var book = book(channel: true)
    let (id, _) = book.ask(session: 1, callID: "c1", question: "Revert?", choices: [], allowText: true, wait: 1,
                           now: t0)
    _ = book.tick(now: at(2))
    let effects = book.answer(id, .text("fix forward"), via: .text)
    #expect(effects.first == .push(1, content: "The user answered your earlier question \"Revert?\" (id \(id)): fix forward",
                                   meta: ["from": "glance", "via": "text", "card": id]))
  }

  @Test func checkAnswerCanWaitAgain() {
    var book = book()
    let (id, _) = book.ask(session: 1, callID: "c1", question: "Q", choices: [], allowText: true, wait: 1, now: t0)
    _ = book.tick(now: at(1))
    #expect(book.checkAnswer(session: 1, callID: "c2", id: id, wait: 30, now: at(2)).isEmpty)
    #expect(book.answer(id, .text("ok"), via: .click).first
      == .reply(1, callID: "c2", value: ["id": .string(id), "answer": "ok", "via": "click"], isError: false))
  }

  @Test func twoWaitersInOneSessionAreAnsweredSeparately() {
    var book = book()
    let (a, _) = book.ask(session: 1, callID: "c1", question: "A", choices: [], allowText: true, wait: 300, now: t0)
    let (b, _) = book.ask(session: 1, callID: "c2", question: "B", choices: [], allowText: true, wait: 300, now: t0)
    #expect(book.answer(b, .text("b"), via: .click).first?.callID == "c2")
    #expect(book.answer(a, .text("a"), via: .click).first?.callID == "c1")
  }

  @Test func anotherSessionCannotCollectOrDismissYourCard() {
    var book = book()
    book.open(.init(id: 2, label: "web", projectDir: nil, surface: nil, channel: false, assistant: false, now: t0))
    let (id, _) = book.ask(session: 1, callID: "c1", question: "Q", choices: [], allowText: true, wait: 300, now: t0)
    #expect(book.checkAnswer(session: 2, callID: "x", id: id, wait: 0, now: t0).first?.isError == true)
    #expect(book.dismiss(session: 2, callID: "y", id: id).first?.isError == true)
    #expect(book.cards.count == 1)
  }

  @Test func dismissAnswersTheWaiterAndTheCall() {
    var book = book()
    let (id, _) = book.ask(session: 1, callID: "c1", question: "Q", choices: [], allowText: true, wait: 300, now: t0)
    #expect(book.dismiss(session: 1, callID: "c2", id: id)
      == [.reply(1, callID: "c1", value: ["id": .string(id), "dismissed": true], isError: false),
          .reply(1, callID: "c2", value: ["ok": true], isError: false)])
  }

  @Test func closeDropsCardsAndKeptAnswersAndTheOrbCalmsDown() {
    var book = book()
    _ = book.ask(session: 1, callID: "c1", question: "Q", choices: [], allowText: true, wait: 300, now: t0)
    _ = book.status(session: 1, callID: "s", state: .working, caption: "Tests", now: t0)
    #expect(book.orbState(now: t0) == .waiting)
    book.close(1)
    #expect(book.cards.isEmpty)
    #expect(book.sessions.isEmpty)
    #expect(book.orbState(now: t0) == nil)
  }

  @Test func permissionCardsSendVerdictsNotReplies() {
    var book = book()
    let request = ChannelWire.PermissionRequest(requestID: "abcde", tool: "Bash", description: "Delete build",
                                                input: #"{"command":"rm -rf build"}"#)
    let id = book.permission(session: 1, request: request, now: t0)
    #expect(id != nil)
    #expect(book.permission(session: 1, request: request, now: t0) == nil)   // a repeat is ignored
    #expect(book.cards.first?.title == "glance wants to use Bash")
    #expect(book.answer(id!, .allow, via: .voice) == [.verdict(1, requestID: "abcde", allow: true)])
  }

  @Test func discardDropsACardWithoutAnyEffect() {
    var book = book()
    let request = ChannelWire.PermissionRequest(requestID: "abcde", tool: "Bash", description: "", input: "{}")
    let id = book.permission(session: 1, request: request, now: t0)!
    book.discard(id)
    #expect(book.cards.isEmpty)
    #expect(book.active == nil)
  }

  @Test func aSessionCannotCheckOrDismissItsPermissionCard() {
    var book = book()
    let request = ChannelWire.PermissionRequest(requestID: "abcde", tool: "Bash", description: "", input: "{}")
    let id = book.permission(session: 1, request: request, now: t0)!
    #expect(book.checkAnswer(session: 1, callID: "c1", id: id, wait: 0, now: t0)
      == [.reply(1, callID: "c1", value: .string("No question or nudge with id \(id) is waiting."), isError: true)])
    #expect(book.dismiss(session: 1, callID: "c2", id: id)
      == [.reply(1, callID: "c2", value: .string("No card with id \(id)."), isError: true)])
    #expect(book.cards.count == 1)
  }

  @Test func aPermissionCardTakesOnlyAllowDenyOrDismiss() {
    var book = book()
    let request = ChannelWire.PermissionRequest(requestID: "abcde", tool: "Bash", description: "", input: "{}")
    let id = book.permission(session: 1, request: request, now: t0)!
    #expect(book.answer(id, .text("sure"), via: .text).isEmpty)
    #expect(book.answer(id, .action("Ship"), via: .click).isEmpty)
    #expect(book.answer(id, .choice("Yes"), via: .click).isEmpty)
    #expect(book.cards.count == 1)   // still there, no verdict sent
    #expect(book.answer(id, .dismissed, via: .click).isEmpty)
    #expect(book.cards.isEmpty)
  }

  @Test func denyOnAPermissionCardSendsANegativeVerdict() {
    var book = book()
    let request = ChannelWire.PermissionRequest(requestID: "abcde", tool: "Bash", description: "", input: "{}")
    let id = book.permission(session: 1, request: request, now: t0)!
    #expect(book.answer(id, .deny, via: .click) == [.verdict(1, requestID: "abcde", allow: false)])
    #expect(book.cards.isEmpty)
  }

  @Test func sessionsSharingALabelGetNumberedHandles() {
    var book = book()
    book.open(.init(id: 2, label: "glance", projectDir: nil, surface: nil, channel: false, assistant: false, now: t0))
    book.open(.init(id: 3, label: "web", projectDir: nil, surface: nil, channel: false, assistant: false, now: t0))
    book.open(.init(id: 4, label: "glance", projectDir: nil, surface: nil, channel: false, assistant: true, now: t0))
    #expect(book.handle(of: 1) == "glance")
    #expect(book.handle(of: 2) == "glance 2")
    #expect(book.handle(of: 3) == "web")
    #expect(book.handle(of: 4) == "glance")   // the assistant never takes part
    #expect(book.session(handle: "glance")?.id == 1)
    #expect(book.session(handle: "glance 2")?.id == 2)
    #expect(book.session(handle: "web")?.id == 3)
    #expect(book.session(handle: "nope") == nil)
    book.close(1)
    #expect(book.handle(of: 2) == "glance")
    #expect(book.session(handle: "glance")?.id == 2)
    #expect(book.session(handle: "glance 2") == nil)
  }

  @Test func theOrbShowsTheMostUrgentState() {
    var book = book()
    book.open(.init(id: 2, label: "web", projectDir: nil, surface: nil, channel: false, assistant: false, now: t0))
    _ = book.status(session: 1, callID: "a", state: .done, caption: nil, now: t0)
    #expect(book.orbState(now: at(1)) == .done)
    _ = book.status(session: 2, callID: "b", state: .working, caption: "Build", now: t0)
    #expect(book.orbState(now: at(1)) == .working)
    _ = book.status(session: 1, callID: "c", state: .error, caption: nil, now: at(2))
    #expect(book.orbState(now: at(3)) == .error)
    // error and done fade after 6 s.
    #expect(book.orbState(now: at(8.5)) == .working)
    _ = book.status(session: 2, callID: "d", state: .idle, caption: nil, now: at(9))
    #expect(book.orbState(now: at(9)) == nil)
    #expect(book.sessions[2]?.caption == "Build")
  }

  @Test func nextCyclesTheActiveCard() {
    var book = book()
    let (a, _) = book.ask(session: 1, callID: "c1", question: "A", choices: [], allowText: true, wait: 300, now: t0)
    let (b, _) = book.ask(session: 1, callID: "c2", question: "B", choices: [], allowText: true, wait: 300, now: at(1))
    #expect(book.active?.id == a)
    book.next()
    #expect(book.active?.id == b)
    book.next()
    #expect(book.active?.id == a)
  }

  @Test func labelsAndSpokenQuestions() {
    #expect(ChannelBook.label(projectDir: "/Users/me/Code/glance", cwd: "/x", home: "/Users/me") == "glance")
    #expect(ChannelBook.label(projectDir: nil, cwd: "/Users/me", home: "/Users/me") == "~")
    #expect(ChannelBook.spokenQuestion(label: "glance", question: "Tests fail on main. What now?",
                                       choices: ["Revert", "Fix forward"])
      == "Claude in glance asks: Tests fail on main. What now? Revert, or Fix forward?")
    #expect(ChannelBook.spokenQuestion(label: "web", question: "Which port?", choices: [])
      == "Claude in web asks: Which port?")
  }
}

private extension ChannelBook.Effect {
  var callID: String? { if case .reply(_, let callID, _, _) = self { callID } else { nil } }
  var isError: Bool { if case .reply(_, _, _, let isError) = self { isError } else { false } }
}
