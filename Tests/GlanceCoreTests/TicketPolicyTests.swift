import Foundation
import Testing
@testable import GlanceCore

private let now = Date(timeIntervalSince1970: 1_760_000_000)
private let start = Ticket.Transition(id: "21", name: "In Progress", category: .inProgress)
private let review = Ticket.Transition(id: "31", name: "In Review", category: .review)
private let done = Ticket.Transition(id: "41", name: "Done", category: .done)

private func ticket(_ category: Ticket.StatusCategory = .todo,
                    transitions: [Ticket.Transition] = [start, review, done]) -> Ticket {
  Ticket(tracker: "jira", key: "ABC-1", title: "T", status: category.title, statusCategory: category,
         transitions: transitions, group: .assigned)
}

private func suggest(_ signal: TicketSignal, _ target: Ticket.StatusCategory?, evidence: String = "e1") -> Suggestion {
  Suggestion(ticketID: "jira:ABC-1", signal: signal, target: target, evidence: "x", evidenceID: evidence, link: nil,
             date: now)
}

private func decide(_ s: Suggestion, _ t: Ticket = ticket(), prefs: TicketPrefs = TicketPrefs(),
                    state: SuggestionState = SuggestionState(), seeding: Bool = false) -> TicketPolicy.Decision {
  TicketPolicy.decide(s, ticket: t, prefs: prefs, state: state, seeding: seeding)
}

@Test func strongForwardSignalsMoveOnTheirOwn() {
  #expect(decide(suggest(.git, .inProgress)) == .auto(start))
  #expect(decide(suggest(.prOpened, .review), ticket(.inProgress)) == .auto(review))
  #expect(decide(suggest(.prMerged, .done), ticket(.review)) == .auto(done))
}

@Test func offMutedAndAlreadyThereDrop() {
  var prefs = TicketPrefs()
  prefs.set(.git, .off)
  #expect(decide(suggest(.git, .inProgress), prefs: prefs) == .drop)
  var state = SuggestionState()
  state.mute("jira:ABC-1")
  #expect(decide(suggest(.git, .inProgress), state: state) == .drop)
  #expect(decide(suggest(.git, .inProgress), ticket(.review)) == .drop)
  #expect(decide(suggest(.prMerged, .done), ticket(.done)) == .drop)
}

@Test func notNowHoldsUntilNewEvidence() {
  var state = SuggestionState()
  _ = state.add(suggest(.prOpened, .review, evidence: "pr:1"))
  state.snooze(suggest(.prOpened, .review, evidence: "pr:1").id)
  #expect(decide(suggest(.prOpened, .review, evidence: "pr:1"), ticket(.inProgress), state: state) == .drop)
  #expect(decide(suggest(.prOpened, .review, evidence: "pr:2"), ticket(.inProgress), state: state) == .auto(review))
}

@Test func twoReviewStatusesAlwaysAsk() {
  let two = ticket(.inProgress, transitions: [review, .init(id: "32", name: "Code Review", category: .review)])
  #expect(decide(suggest(.prOpened, .review), two) == .nudge)
}

@Test func unknownStatusesAndNudgeSignalsAsk() {
  #expect(decide(suggest(.git, .inProgress), ticket(.unknown)) == .nudge)
  #expect(decide(suggest(.session, .inProgress)) == .nudge)
  #expect(decide(suggest(.stale, nil), ticket(.inProgress)) == .nudge)
  var prefs = TicketPrefs()
  prefs.set(.session, .auto)
  #expect(decide(suggest(.session, .inProgress), prefs: prefs) == .auto(start))
  prefs.set(.git, .nudge)
  #expect(decide(suggest(.git, .inProgress), prefs: prefs) == .nudge)
}

@Test func aFailedAutoMoveAsksNextTime() {
  var state = SuggestionState()
  state.setAutoBlocked("jira:ABC-1", true)
  #expect(decide(suggest(.git, .inProgress), state: state) == .nudge)
}

@Test func theFirstScanOnlyNudges() {
  #expect(decide(suggest(.git, .inProgress), seeding: true) == .nudge)
}

@Test func forwardIsAlongTheWorkflow() {
  #expect(TicketPolicy.isForward(from: .todo, to: .done))
  #expect(!TicketPolicy.isForward(from: .review, to: .inProgress))
  #expect(!TicketPolicy.isForward(from: .unknown, to: .done))
}
