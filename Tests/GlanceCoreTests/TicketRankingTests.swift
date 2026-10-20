import Foundation
import Testing
@testable import GlanceCore

private let now = Date(timeIntervalSince1970: 1_760_000_000)

private func ticket(_ key: String, priority: String? = nil, severity: String? = nil, due: Date? = nil,
                    category: Ticket.StatusCategory = .todo, group: Ticket.Group = .assigned,
                    updated: Date? = nil) -> Ticket {
  Ticket(tracker: "jira", key: key, title: "T \(key)", status: category.title, statusCategory: category,
         priority: priority, severity: severity, due: due, updated: updated, transitions: [], group: group)
}

@Test func theDefaultInstructionsOrUsersOwnComeFirstAndTheContractLast() throws {
  let tickets = [ticket("ABC-1", priority: "High")]
  let byDefault = TicketRanking.prompt(tickets: tickets, evidence: ["jira:ABC-1": ["PR #4 open"]], instructions: "  ",
                                       now: now)
  #expect(byDefault.hasPrefix(TicketRanking.defaultInstructions))
  #expect(byDefault.contains("ABC-1") && byDefault.contains("PR #4 open"))
  let custom = TicketRanking.prompt(tickets: tickets, evidence: [:], instructions: "Due date only. Ignore priority.",
                                    now: now)
  #expect(custom.hasPrefix("Due date only. Ignore priority."))
  #expect(!custom.contains("Blockers"))
  let contract = try #require(custom.range(of: #""order""#))
  let list = try #require(custom.range(of: "ABC-1"))
  #expect(list.lowerBound < contract.lowerBound)
}

@Test func doneTicketsAreLeftOutOfThePrompt() {
  let prompt = TicketRanking.prompt(tickets: [ticket("ABC-1"), ticket("ABC-2", category: .done)], evidence: [:],
                                    instructions: "", now: now)
  #expect(prompt.contains("ABC-1") && !prompt.contains("ABC-2"))
}

@Test func aRankKeepsKnownKeysInTheirGroups() throws {
  let tickets = [ticket("ABC-1"), ticket("ABC-2"), ticket("ABC-9", group: .upNext), ticket("ABC-8", group: .upNext)]
  let reply = """
    {"order":[{"key":"abc-2","reason":"Blocks release"},{"key":"ABC-2","reason":"dup"},{"key":"NOPE-1","reason":"x"},
              {"key":"ABC-9","reason":"wrong group"},{"key":"ABC-1","reason":"Due Friday"}],
     "pickUp":[{"key":"ABC-8","reason":"Small"},{"key":"ABC-1","reason":"wrong group"}],
     "summary":"A release day."}
    """
  let rank = try #require(TicketRanking.parse(reply, tickets: tickets, at: now))
  #expect(rank.order.map(\.key) == ["ABC-2", "ABC-1"])
  #expect(rank.order.first?.reason == "Blocks release")
  #expect(rank.pickUp.map(\.key) == ["ABC-8"])
  #expect(rank.summary == "A release day.")
}

@Test func aProseReplyFallsBackToThePlainOrder() {
  let tickets = [ticket("ABC-1", priority: "Low"), ticket("ABC-2", priority: "Highest")]
  #expect(TicketRanking.parse("Sure! 1. ABC-2 2. ABC-1", tickets: tickets, at: now) == nil)
  let arranged = TicketRanking.arrange(tickets, rank: nil)
  #expect(arranged.today.map(\.ticket.key) == ["ABC-2", "ABC-1"])
  #expect(!arranged.ranked)
  #expect(arranged.today.allSatisfy { $0.reason == nil })
}

@Test func urgencyReadsCommonPriorityAndSeverityNames() {
  #expect(TicketRanking.urgency("Blocker") == 0)
  #expect(TicketRanking.urgency("Highest") == 0)
  #expect(TicketRanking.urgency("Urgent") == 0)
  #expect(TicketRanking.urgency("High") == 1)
  #expect(TicketRanking.urgency("Medium") == 2)
  #expect(TicketRanking.urgency("Low") == 3)
  #expect(TicketRanking.urgency("Lowest") == 4)
  #expect(TicketRanking.urgency("No priority") == 5)
  #expect(TicketRanking.urgency(nil) == 5)
}

@Test func thePlainOrderIsUrgencyThenDueThenStartedThenRecent() {
  let soon = now.addingTimeInterval(86_400), later = now.addingTimeInterval(5 * 86_400)
  let tickets = [
    ticket("A", priority: "Medium", due: later),
    ticket("B", priority: "Medium", due: soon),
    ticket("C", priority: "Low", severity: "Critical"),
    ticket("D", priority: "Medium", due: later, category: .inProgress),
    ticket("E"),
  ]
  #expect(TicketRanking.fallback(tickets).map(\.key) == ["C", "B", "D", "A", "E"])
}

@Test func arrangePutsTheRankFirstAndTheRestInThePlainOrder() {
  let tickets = [ticket("ABC-1", priority: "High"), ticket("ABC-2", priority: "Low"), ticket("ABC-3", priority: "Highest"),
                 ticket("ABC-4", category: .done), ticket("ABC-9", group: .upNext)]
  let rank = TicketRank(order: [.init(key: "ABC-2", reason: "Customer waiting")], pickUp: [], summary: "", date: now)
  let arranged = TicketRanking.arrange(tickets, rank: rank)
  #expect(arranged.today.map(\.ticket.key) == ["ABC-2", "ABC-3", "ABC-1"])
  #expect(arranged.today.first?.reason == "Customer waiting")
  #expect(arranged.upNext.map(\.ticket.key) == ["ABC-9"])
  #expect(arranged.ranked)
}

@Test func theSpokenBriefNamesTheTopThree() {
  let top = [ticket("ABC-1"), ticket("ABC-2")].map { TicketRanking.Ranked(ticket: $0, reason: nil) }
  let text = TicketRanking.spoken(top: top, summary: "A quiet day.", name: "Gobinda")
  #expect(text.hasPrefix("Good morning Gobinda. A quiet day."))
  #expect(text.contains("First, ABC-1: T ABC-1.") && text.contains("Then ABC-2: T ABC-2."))
  #expect(TicketRanking.spoken(top: [], summary: "", name: nil) == "Good morning. Nothing is assigned to you today.")
}
