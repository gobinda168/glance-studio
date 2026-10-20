import Foundation
import Testing
@testable import GlanceCore

private let jira = Tracker(server: "claude.ai Atlassian", readTools: ["mcp__a__get", "mcp__a__search"],
                           moveTools: ["mcp__a__transition"], commentTools: ["mcp__a__comment"])
private let now = Date(timeIntervalSince1970: 1_760_000_000)

@Test func runsAllowOnlyTheirTools() {
  let read = TicketPrompts.arguments(tools: jira.readTools, model: "haiku")
  #expect(read.contains("--allowedTools"))
  #expect(read[read.firstIndex(of: "--allowedTools")! + 1] == "mcp__a__get,mcp__a__search")
  #expect(!read.contains("--strict-mcp-config"))
  #expect(read.suffix(2) == ["--model", "haiku"])
  #expect(read.contains("--no-session-persistence"))
  let rank = TicketPrompts.arguments(tools: [], model: nil)
  #expect(rank.contains("--strict-mcp-config"))
  #expect(!rank.contains("--allowedTools"))
  #expect(!rank.contains("--model"))
}

@Test func theFetchPromptAsksForTheDefaultSetOrTheQuery() {
  let byDefault = TicketPrompts.fetchPrompt(jira, query: nil, now: now)
  #expect(byDefault.contains("assigned to the user"))
  #expect(byDefault.contains("current sprint"))
  #expect(byDefault.contains("Read only"))
  #expect(byDefault.contains("\"transitions\""))
  let custom = TicketPrompts.fetchPrompt(jira, query: "project = ABC AND sprint in openSprints()", now: now)
  #expect(custom.contains("project = ABC AND sprint in openSprints()"))
  #expect(!custom.contains("current sprint"))
}

@Test func ticketsParseFromAFencedReply() throws {
  let reply = """
    Here they are:
    ```json
    {"tickets":[
      {"key":"ABC-123","title":"Login fails","status":"In Progress","statusCategory":"inProgress","priority":"High",
       "severity":null,"assignee":"Gobinda","due":"2026-10-12","updated":"2026-10-09T10:00:00.000Z",
       "url":"https://acme.atlassian.net/browse/ABC-123","sprint":"Sprint 42","repository":null,"group":"assigned",
       "transitions":[{"id":"31","name":"In Review","category":"review"},{"id":"41","name":"Done","category":"done"}]},
      {"key":"ABC-200","title":"Pick me","status":"To Do","statusCategory":"weird","group":"upNext","transitions":[]},
      {"title":"no key"}
    ]}
    ```
    """
  let tickets = try TicketPrompts.tickets(from: reply, tracker: "claude.ai Atlassian").get()
  #expect(tickets.map(\.key) == ["ABC-123", "ABC-200"])
  let first = tickets[0]
  #expect(first.tracker == "claude.ai Atlassian")
  #expect(first.statusCategory == .inProgress)
  #expect(first.priority == "High" && first.severity == nil)
  #expect(first.due != nil && first.updated != nil)
  #expect(first.url?.absoluteString == "https://acme.atlassian.net/browse/ABC-123")
  #expect(first.transitions.map(\.category) == [.review, .done])
  #expect(tickets[1].statusCategory == .unknown)
  #expect(tickets[1].group == .upNext)
}

@Test func gitHubIssueKeysCarryTheirRepository() throws {
  let reply = ##"{"tickets":[{"key":"#88","title":"Bug","status":"open","statusCategory":"todo","repository":"acme/api","group":"assigned","transitions":[]}]}"##
  let tickets = try TicketPrompts.tickets(from: reply, tracker: "github").get()
  #expect(tickets.first?.key == "acme/api#88")
}

@Test func errorsAndJunkAreFailures() {
  #expect(TicketPrompts.tickets(from: #"{"error":"Not signed in to Jira"}"#, tracker: "t")
    == .failure(TicketFailure(message: "Not signed in to Jira")))
  #expect(TicketPrompts.tickets(from: "I couldn't do that.", tracker: "t")
    == .failure(TicketFailure(message: "Claude's answer wasn't the JSON Glance asked for.")))
  #expect((try? TicketPrompts.tickets(from: #"{"tickets":[]}"#, tracker: "t").get()) == [])
}

@Test func usageLimitsAreRecognised() {
  #expect(TicketPrompts.isUsageLimit("Claude AI usage limit reached|1760003600"))
  #expect(TicketPrompts.isUsageLimit("You've hit your limit · resets 3pm"))
  #expect(!TicketPrompts.isUsageLimit("Not signed in to Jira"))
}

@Test func datesParseInTheirCommonShapes() {
  #expect(TicketPrompts.date("2026-10-09T10:00:00Z") != nil)
  #expect(TicketPrompts.date("2026-10-09T10:00:00.123Z") != nil)
  #expect(TicketPrompts.date("2026-10-12") != nil)
  #expect(TicketPrompts.date("soon") == nil)
  #expect(TicketPrompts.date(nil) == nil)
}

@Test func theMovePromptNamesTheTicketTheStatusAndTheComment() {
  let ticket = Ticket(tracker: "claude.ai Atlassian", key: "ABC-123", title: "Login fails", status: "To Do",
                      statusCategory: .todo, transitions: [], group: .upNext)
  let prompt = TicketPrompts.movePrompt(ticket, to: .init(id: "21", name: "In Progress", category: .inProgress),
                                        assignToMe: true, comment: "PR #412 opened — moved by Glance", tracker: jira)
  #expect(prompt.contains("ABC-123") && prompt.contains("\"In Progress\"") && prompt.contains("transition id 21"))
  #expect(prompt.contains("Assign it to the user"))
  #expect(prompt.contains("PR #412 opened — moved by Glance"))
  #expect(prompt.contains("Change nothing else"))
  #expect(TicketPrompts.moveTools(jira, comment: false) == ["mcp__a__transition", "mcp__a__get", "mcp__a__search"])
  #expect(TicketPrompts.moveTools(jira, comment: true).last == "mcp__a__comment")
}

@Test func moveAnswersParse() {
  #expect(TicketPrompts.moved(from: #"{"ok":true,"status":"In Review"}"#) == .success("In Review"))
  #expect(TicketPrompts.moved(from: #"{"ok":true}"#) == .success(nil))
  #expect(TicketPrompts.moved(from: #"{"ok":false,"error":"No such transition"}"#)
    == .failure(TicketFailure(message: "No such transition")))
  #expect(TicketPrompts.moved(from: "Done!") == .failure(TicketFailure(message: TicketPrompts.notJSON)))
}

@Test func aProposedEditIsOnlyAMoveTheTicketCanMake() {
  var ticket = Ticket(tracker: "claude.ai Atlassian", key: "ABC-1", title: "Fix login", status: "To Do",
                      statusCategory: .todo, transitions: [], group: .assigned)
  ticket.transitions = [Ticket.Transition(id: "31", name: "In Review", category: .review)]
  let prompt = TicketPrompts.editPrompt(ticket, request: "send it to review")
  #expect(prompt.contains(#"id "31": In Review"#))
  #expect(prompt.contains("send it to review"))
  let move = try? TicketPrompts.edit(from: #"{"transition":"31","note":"Moving it."}"#, for: ticket).get()
  #expect(move?.transition?.name == "In Review")
  let unknown = try? TicketPrompts.edit(from: #"{"transition":"99","note":""}"#, for: ticket).get()
  #expect(unknown?.transition == nil)
  let none = try? TicketPrompts.edit(from: #"{"transition":null,"note":"Can't rename."}"#, for: ticket).get()
  #expect(none?.transition == nil && none?.note == "Can't rename.")
  if case .success = TicketPrompts.edit(from: "sorry", for: ticket) { Issue.record("junk should fail") }
}
