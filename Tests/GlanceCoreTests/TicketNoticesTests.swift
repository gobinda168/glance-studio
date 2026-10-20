import Foundation
import Testing
@testable import GlanceCore

private let now = Date(timeIntervalSince1970: 1_760_000_000)
private let review = Ticket.Transition(id: "31", name: "In Review", category: .review)
private let done = Ticket.Transition(id: "41", name: "Done", category: .done)
private let ticket = Ticket(tracker: "jira", key: "ABC-123", title: "Login fails", status: "In Progress",
                            statusCategory: .inProgress, url: URL(string: "https://acme.atlassian.net/browse/ABC-123"),
                            transitions: [review, done], group: .assigned)

@Test func aSuggestionWithOneTransitionOffersTheMove() {
  let suggestion = Suggestion(ticketID: ticket.id, signal: .prOpened, target: .review, evidence: "PR #412 opened",
                              evidenceID: "pr:acme/api#412:open", link: nil, date: now)
  let notice = TicketNotices.suggestion(suggestion, ticket: ticket)
  #expect(notice.source == .tickets && notice.kind == .ticketSuggestion)
  #expect(notice.title == "ABC-123" && notice.place == "PR #412 opened" && notice.preview == "Login fails")
  #expect(notice.threadKey == "tickets:jira:ABC-123")
  #expect(notice.target == .link(URL(string: "https://acme.atlassian.net/browse/ABC-123")!))
  #expect(notice.actions?.map(\.title) == ["Move to In Review", "Not now"])
  #expect(notice.actions?.first?.id == "move:31")
  #expect(notice.moreActions?.map(\.title) == ["Move to Done", "Don't ask for this ticket"])
  #expect(notice.meta["ticket"] == ticket.id)
}

@Test func aStaleTicketAsksWhatToDo() {
  let stale = Suggestion(ticketID: ticket.id, signal: .stale, target: nil, evidence: "No activity for 4 days",
                         evidenceID: "stale:1", link: nil, date: now)
  let notice = TicketNotices.suggestion(stale, ticket: ticket)
  #expect(notice.actions?.map(\.title) == ["Still on it", "Choose status"])
  #expect(notice.moreActions?.map(\.title) == ["Move to In Review", "Move to Done", "Don't ask for this ticket"])
}

@Test func twoTransitionsInTheTargetCategoryMeanChoosing() {
  var two = ticket
  two.transitions = [review, .init(id: "32", name: "Code Review", category: .review)]
  #expect(two.onlyTransition(to: .review) == nil)
  #expect(ticket.onlyTransition(to: .review) == review)
  let suggestion = Suggestion(ticketID: two.id, signal: .prOpened, target: .review, evidence: "PR #1 opened",
                              evidenceID: "x", link: nil, date: now)
  #expect(TicketNotices.suggestion(suggestion, ticket: two).actions?.map(\.title) == ["Choose status", "Not now"])
}

@Test func movesAndFailuresCarryUndoAndRetry() {
  let move = TicketMove(id: "m1", ticketID: ticket.id, key: "ABC-123", from: "In Progress", fromCategory: .inProgress,
                        to: "In Review", toCategory: .review, reason: "PR #412 opened", auto: true, date: now)
  let moved = TicketNotices.moved(move, ticket: ticket)
  #expect(moved.kind == .ticketMoved && moved.place == "Moved to In Review")
  #expect(moved.actions == [Notice.Action(id: "undo:m1", title: "Undo")])
  let failed = TicketNotices.failed(ticket, transition: done, message: "Permission denied", at: now)
  #expect(failed.kind == .ticketFailed && failed.place == "Couldn't move to Done" && failed.preview == "Permission denied")
  #expect(failed.actions?.map(\.id) == ["retry:41", "choose"])
}

@Test func actionIdsRoundTrip() {
  for action in [TicketNotices.Action.move("31"), .snooze("t>review"), .mute, .undo("m1"), .retry("41"), .choose] {
    #expect(TicketNotices.Action(id: action.id) == action)
  }
  #expect(TicketNotices.Action(id: "nonsense") == nil)
}

@Test func morningAndCheckInNeverNudgeTheStack() {
  let morning = TicketNotices.morning(summary: "A release day.", keys: ["ABC-1"], at: now)
  #expect(!NudgeRules.shouldNudge(morning, prefs: .defaults, now: now, inMeeting: false))
  let suggestion = TicketNotices.suggestion(
    Suggestion(ticketID: ticket.id, signal: .git, target: .review, evidence: "e", evidenceID: "e", link: nil, date: now),
    ticket: ticket)
  #expect(NudgeRules.shouldNudge(Notice(id: suggestion.id, source: .tickets, kind: .ticketSuggestion, title: "x",
                                        place: nil, preview: "", date: now, threadKey: "k", target: .none),
                                 prefs: .defaults, now: now, inMeeting: false))
}
