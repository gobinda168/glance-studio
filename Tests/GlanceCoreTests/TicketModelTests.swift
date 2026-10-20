import Foundation
import Testing
@testable import GlanceCore

private let now = Date(timeIntervalSince1970: 1_760_000_000)

private func ticket(_ key: String, tracker: String = "claude.ai Atlassian", category: Ticket.StatusCategory = .todo,
                    group: Ticket.Group = .assigned) -> Ticket {
  Ticket(tracker: tracker, key: key, title: "Title \(key)", status: category.title, statusCategory: category,
         transitions: [], group: group)
}

@Test func trackersHaveFriendlyNames() {
  #expect(Tracker(server: "claude.ai Atlassian", readTools: [], moveTools: [], commentTools: []).name == "Jira")
  #expect(Tracker(server: "linear", readTools: [], moveTools: [], commentTools: []).name == "Linear")
  #expect(Tracker(server: "claude.ai GitHub", readTools: [], moveTools: [], commentTools: []).name == "GitHub")
  #expect(Tracker(server: "claude.ai Shortcut", readTools: [], moveTools: [], commentTools: []).name == "Shortcut")
}

@Test func categoriesHaveAnOrderButUnknownHasNone() {
  #expect(Ticket.StatusCategory.todo.step == 0)
  #expect(Ticket.StatusCategory.done.step == 3)
  #expect(Ticket.StatusCategory.unknown.step == nil)
  #expect(ticket("ABC-1").id == "claude.ai Atlassian:ABC-1")
}

@Test func aFetchReplacesOnlyItsTracker() {
  var book = TicketBook()
  book.merge([ticket("ABC-1"), ticket("ABC-2"), ticket("ABC-2")], tracker: "claude.ai Atlassian", at: now)
  book.merge([ticket("ENG-1", tracker: "linear")], tracker: "linear", at: now)
  book.merge([ticket("ABC-3")], tracker: "claude.ai Atlassian", at: now.addingTimeInterval(60))
  #expect(book.tickets.map(\.key).sorted() == ["ABC-3", "ENG-1"])
  #expect(book.fetched["claude.ai Atlassian"] == now.addingTimeInterval(60))
  #expect(book.asOf == now)
}

@Test func movesAreKeptNewestFirstAndCapped() {
  var book = TicketBook()
  for index in 0..<(TicketBook.keepMoves + 5) {
    book.record(TicketMove(id: "\(index)", ticketID: "t", key: "ABC-1", from: "To Do", fromCategory: .todo,
                           to: "In Progress", toCategory: .inProgress, reason: "commit", auto: true,
                           date: now.addingTimeInterval(Double(index))))
  }
  #expect(book.moves.count == TicketBook.keepMoves)
  #expect(book.moves.first?.id == "\(TicketBook.keepMoves + 4)")
  #expect(book.moves(on: now, calendar: .current).count == TicketBook.keepMoves)
}

@Test func activityKeepsTheLatestDate() {
  var book = TicketBook()
  book.noteActivity("t", at: now)
  book.noteActivity("t", at: now.addingTimeInterval(-100))
  #expect(book.activity["t"] == now)
}

@Test func sessionsOnlyKeepTheLatestDay() {
  var book = TicketBook()
  book.note(SessionNote(file: "a", folder: nil, prompts: ["x"], date: now.addingTimeInterval(-3 * 86_400)))
  book.note(SessionNote(file: "b", folder: nil, prompts: ["y"], date: now))
  book.note(SessionNote(file: "b", folder: nil, prompts: ["y", "z"], date: now))
  #expect(book.sessions.map(\.file) == ["b"])
  #expect(book.sessions.first?.prompts == ["y", "z"])
}

@Test func theBookRoundTripsAndJunkDoesNot() {
  var book = TicketBook()
  book.merge([ticket("ABC-1")], tracker: "claude.ai Atlassian", at: now)
  book.lastMorning = "2026-10-09"
  #expect(TicketBook.decode(book.encoded()) == book)
  #expect(TicketBook.decode(Data("nope".utf8)) == nil)
}

@Test func prefsDefaultToAutoOnlyForStrongSignals() {
  let prefs = TicketPrefs()
  #expect(prefs.mode(.git) == .auto)
  #expect(prefs.mode(.prOpened) == .auto)
  #expect(prefs.mode(.prMerged) == .auto)
  #expect(prefs.mode(.session) == .nudge)
  #expect(prefs.mode(.stale) == .nudge)
  #expect(prefs.mode(.checkIn) == .nudge)
}

@Test func staleAndCheckInCanNeverBeAuto() {
  var prefs = TicketPrefs()
  prefs.set(.stale, .auto)
  prefs.set(.session, .auto)
  #expect(prefs.mode(.stale) == .nudge)
  #expect(prefs.mode(.session) == .auto)
  prefs.queries["claude.ai Atlassian"] = "  "
  #expect(prefs.query(for: "claude.ai Atlassian") == nil)
}

@Test func prefsDecodeFromAnOlderShape() throws {
  let prefs = try JSONDecoder().decode(TicketPrefs.self, from: Data(#"{"staleDays":5}"#.utf8))
  #expect(prefs.staleDays == 5)
  #expect(prefs.morningMinutes == TicketPrefs.defaultMorning)
}

private func suggestion(_ ticketID: String = "t", target: Ticket.StatusCategory? = .review,
                        evidence: String = "pr:1:open") -> Suggestion {
  Suggestion(ticketID: ticketID, signal: .prOpened, target: target, evidence: "PR #1 opened", evidenceID: evidence,
             link: nil, date: now)
}

@Test func aPendingSuggestionMergesInsteadOfRepeating() {
  var state = SuggestionState()
  let first = state.add(suggestion())
  let again = state.add(suggestion(evidence: "pr:2:open"))
  #expect(first)
  #expect(!again)
  #expect(state.pending.count == 1)
  #expect(state.pending.first?.evidenceID == "pr:2:open")
}

@Test func snoozingWaitsForNewEvidence() {
  var state = SuggestionState()
  let first = suggestion()
  _ = state.add(first)
  state.snooze(first.id)
  #expect(state.pending.isEmpty)
  #expect(state.isSnoozed(first))
  #expect(!state.isSnoozed(suggestion(evidence: "pr:9:open")))
}

@Test func aMoveResolvesEverySuggestionForItsTicket() {
  var state = SuggestionState()
  _ = state.add(suggestion(target: .review))
  _ = state.add(suggestion(target: .done))
  _ = state.add(suggestion("other"))
  state.resolve(ticketID: "t")
  #expect(state.pending.map(\.ticketID) == ["other"])
  #expect(suggestion(target: nil).id == "t>choose")
}

@Test func ticketsSitUnderPullRequestsOnTheStrip() {
  let strip = SidebarMode.stripModes(enabled: [.tickets])
  #expect(strip.firstIndex(of: .tickets) == strip.firstIndex(of: .pullRequests).map { $0 + 1 })
  #expect(!SidebarMode.stripModes(enabled: []).contains(.tickets))
  #expect(!SettingsSection.tickets.isShown(enabled: []))
  #expect(Feature.tickets.isGA)
  #expect(SettingsCatalog.entries.contains { $0.id == "tickets.ranking" })
}

@Test func aGlanceTrackerIsKeyedOnItsSite() {
  let tracker = Tracker.glance(site: "S1", name: "Acme")
  #expect(tracker.server == "glance:S1")
  #expect(tracker.kind == .glance && tracker.site == "S1" && tracker.name == "Acme")
  #expect(Tracker.siteID(fromServer: "glance:S1") == "S1")
  #expect(Tracker.siteID(fromServer: "claude.ai Atlassian") == nil)
}

@Test func aTrackerSavedBeforeKindsDecodesAsClaude() throws {
  let old = #"{"server":"claude.ai Atlassian","readTools":["a"],"moveTools":[],"commentTools":[]}"#
  let tracker = try JSONDecoder().decode(Tracker.self, from: Data(old.utf8))
  #expect(tracker.kind == .claude && tracker.site == nil && tracker.name == "Jira")
}

@Test func dropCoveredKeepsOtherHostsAndTheKeptTrackers() {
  func ticket(_ tracker: String, _ key: String, _ url: String) -> Ticket {
    Ticket(tracker: tracker, key: key, title: key, status: "To Do", statusCategory: .todo, url: URL(string: url),
           transitions: [], group: .assigned)
  }
  var book = TicketBook()
  book.merge([ticket("claude.ai Atlassian", "A-1", "https://acme.atlassian.net/browse/A-1"),
              ticket("claude.ai Atlassian", "B-1", "https://other.atlassian.net/browse/B-1")],
             tracker: "claude.ai Atlassian", at: Date())
  book.merge([ticket("glance:S1", "A-1", "https://acme.atlassian.net/browse/A-1")], tracker: "glance:S1", at: Date())
  book.dropCovered(hosts: ["acme.atlassian.net"], keep: ["glance:S1"])
  #expect(book.tickets.map(\.id).sorted() == ["claude.ai Atlassian:B-1", "glance:S1:A-1"])
}
