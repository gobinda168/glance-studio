import Foundation
import Testing
@testable import GlanceCore

private let now = Date(timeIntervalSince1970: 1_760_000_000)
private let review = Ticket.Transition(id: "31", name: "In Review", category: .review)

private func ticket(_ key: String, _ category: Ticket.StatusCategory = .inProgress) -> Ticket {
  Ticket(tracker: "jira", key: key, title: "T \(key)", status: category.title, statusCategory: category,
         transitions: [review], group: .assigned)
}

@Test func touchedTicketsComeWithTheirSuggestion() {
  var book = TicketBook()
  book.merge([ticket("ABC-1"), ticket("ABC-2"), ticket("ABC-3"), ticket("ABC-4", .done)], tracker: "jira", at: now)
  book.noteActivity("jira:ABC-1", at: now)
  book.noteActivity("jira:ABC-2", at: now.addingTimeInterval(-3 * 86_400))
  book.noteActivity("jira:ABC-4", at: now)
  _ = book.suggestions.add(Suggestion(ticketID: "jira:ABC-1", signal: .prOpened, target: .review,
                                      evidence: "PR #4 opened", evidenceID: "x", link: nil, date: now))
  let rows = TicketCheckIn.rows(book: book, matched: ["jira:ABC-3"], now: now, calendar: .current)
  #expect(rows.map(\.ticket.key) == ["ABC-1", "ABC-3"])
  #expect(rows[0].transition == review && rows[0].suggestion?.evidence == "PR #4 opened")
  #expect(rows[1].suggestion == nil && rows[1].transition == nil)
}

@Test func onlySessionsWithoutAKeyAreAskedAbout() {
  let tickets = [ticket("ABC-1")]
  let sessions = [SessionNote(file: "a", folder: "/x", prompts: ["work on ABC-1"], date: now),
                  SessionNote(file: "b", folder: "/x", prompts: ["fix the login redirect"], date: now)]
  #expect(TicketCheckIn.unmatched(sessions, tickets: tickets).map(\.file) == ["b"])
}

@Test func theMatchPromptAndItsAnswer() {
  let tickets = [ticket("ABC-1"), ticket("ABC-2")]
  let prompt = TicketCheckIn.matchPrompt(tickets: tickets,
                                         sessions: [SessionNote(file: "b", folder: "/Code/api",
                                                                prompts: ["fix the login redirect"], date: now)])
  #expect(prompt.contains("ABC-1 · T ABC-1") && prompt.contains("1. /Code/api — fix the login redirect"))
  #expect(prompt.contains(#"{"matches":"#))
  #expect(TicketCheckIn.matched(from: #"{"matches":[{"key":"abc-2","session":1},{"key":"NOPE","session":1}]}"#,
                                tickets: tickets) == ["jira:ABC-2"])
  #expect(TicketCheckIn.matched(from: "none", tickets: tickets).isEmpty)
}
