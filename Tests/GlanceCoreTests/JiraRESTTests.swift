import Foundation
import Testing
@testable import GlanceCore

private let cloud = AtlassianSite.cloud(base: URL(string: "https://acme.atlassian.net")!)
private let dc: AtlassianSite = AtlassianAPI.site(URL(string: "https://jira.corp.example/jira")!, product: .jira)

private func query(_ request: URLRequest?) -> [String: String] {
  let items = URLComponents(url: request!.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
  return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
}

@Test func searchUsesEachFlavoursPath() {
  let c = JiraREST.searchRequest(cloud, jql: JiraREST.assignedJQL, sprintField: "customfield_10020", credential: .session)
  #expect(c?.url?.path == "/rest/api/2/search/jql")
  #expect(query(c)["jql"] == JiraREST.assignedJQL)
  #expect(query(c)["expand"] == "transitions")
  #expect(query(c)["fields"] == "summary,status,priority,assignee,duedate,updated,customfield_10020")
  let d = JiraREST.searchRequest(dc, jql: "project = X", sprintField: nil, credential: .personalToken("t"))
  #expect(d?.url?.path == "/jira/rest/api/2/search")
  #expect(query(d)["fields"] == "summary,status,priority,assignee,duedate,updated")
  #expect(d?.value(forHTTPHeaderField: "Authorization") == "Bearer t")
}

@Test func sprintFieldIsFoundByNameOrSchema() {
  let byName = #"[{"id":"summary","name":"Summary"},{"id":"customfield_10020","name":"Sprint","schema":{"custom":"com.pyxis.greenhopper.jira:gh-sprint"}}]"#
  #expect(JiraREST.sprintField(Data(byName.utf8)) == "customfield_10020")
  let bySchema = #"[{"id":"customfield_7","name":"Iteration","schema":{"custom":"com.pyxis.greenhopper.jira:gh-sprint"}}]"#
  #expect(JiraREST.sprintField(Data(bySchema.utf8)) == "customfield_7")
  #expect(JiraREST.sprintField(Data("[]".utf8)) == nil)
}

private let search = #"""
{"issues":[{"key":"ACME-12","fields":{"summary":"Fix login","status":{"name":"In Review","statusCategory":{"key":"indeterminate"}},
"priority":{"name":"High"},"assignee":{"displayName":"Gobinda"},"duedate":"2026-10-15","updated":"2026-10-11T09:12:33.000+0530",
"customfield_10020":[{"name":"Sprint 3","state":"closed"},{"name":"Sprint 4","state":"active"}]},
"transitions":[{"id":"31","name":"Done","to":{"name":"Done","statusCategory":{"key":"done"}}},
{"id":"21","name":"Back to progress","to":{"name":"In Progress","statusCategory":{"key":"indeterminate"}}}]},
{"key":"ACME-13","fields":{"summary":"New thing","status":{"name":"To Do","statusCategory":{"key":"new"}}}}]}
"""#

@Test func searchAnswerBecomesTickets() throws {
  let tickets = try #require(JiraREST.tickets(Data(search.utf8), site: cloud, tracker: "glance:S", group: .assigned,
                                              sprintField: "customfield_10020"))
  #expect(tickets.map(\.key) == ["ACME-12", "ACME-13"])
  let first = tickets[0]
  #expect(first.tracker == "glance:S" && first.title == "Fix login" && first.status == "In Review")
  #expect(first.statusCategory == .review)
  #expect(first.priority == "High" && first.assignee == "Gobinda" && first.sprint == "Sprint 4")
  #expect(first.url?.absoluteString == "https://acme.atlassian.net/browse/ACME-12")
  #expect(first.due != nil && first.updated != nil)
  #expect(first.transitions == [Ticket.Transition(id: "31", name: "Done", category: .done),
                                Ticket.Transition(id: "21", name: "Back to progress", category: .inProgress)])
  #expect(first.group == .assigned)
  #expect(tickets[1].statusCategory == .todo && tickets[1].transitions.isEmpty && tickets[1].sprint == nil)
}

@Test func dataCenterSprintStringsGiveTheirName() {
  #expect(JiraREST.sprintName(["com.atlassian.greenhopper.service.sprint.Sprint@1a[id=4,rapidViewId=2,state=ACTIVE,name=Sprint 9,startDate=2026]"]) == "Sprint 9")
  #expect(JiraREST.sprintName(nil) == nil)
}

@Test func statusCategoriesMapLikeTickets() {
  #expect(JiraREST.category(key: "new", name: "Backlog") == .todo)
  #expect(JiraREST.category(key: "indeterminate", name: "In Progress") == .inProgress)
  #expect(JiraREST.category(key: "indeterminate", name: "Code review") == .review)
  #expect(JiraREST.category(key: "done", name: "Closed") == .done)
  #expect(JiraREST.category(key: nil, name: "Odd") == .unknown)
}

@Test func aSearchAnswerThatIsntJSONIsAFailure() {
  #expect(JiraREST.tickets(Data("<html>Sign in</html>".utf8), site: cloud, tracker: "t", group: .assigned,
                           sprintField: nil) == nil)
  #expect(JiraREST.failure(status: 200, data: Data(), site: cloud, key: nil).message
    == "acme.atlassian.net didn't answer with tickets. Sign in again in its Jira tab.")
}

@Test func mergedSearchesKeepAKeyOnce() {
  func t(_ key: String, _ group: Ticket.Group) -> Ticket {
    Ticket(tracker: "g", key: key, title: key, status: "s", statusCategory: .todo, transitions: [], group: group)
  }
  #expect(JiraREST.merged([[t("A", .assigned)], [t("A", .upNext), t("B", .upNext)]]).map { "\($0.key)\($0.group)" }
    == ["Aassigned", "BupNext"])
}

@Test func writesAreTheirJiraCalls() throws {
  let move = try #require(JiraREST.transitionRequest(cloud, key: "ACME-12", transitionID: "31", credential: .session))
  #expect(move.httpMethod == "POST" && move.url?.path == "/rest/api/2/issue/ACME-12/transitions")
  #expect(move.value(forHTTPHeaderField: "X-Atlassian-Token") == "no-check")
  #expect(String(decoding: move.httpBody ?? Data(), as: UTF8.self) == #"{"transition":{"id":"31"}}"#)
  let comment = try #require(JiraREST.commentRequest(dc, key: "X-1", body: "PR #4 merged", credential: .session))
  #expect(comment.url?.path == "/jira/rest/api/2/issue/X-1/comment")
  #expect(String(decoding: comment.httpBody ?? Data(), as: UTF8.self) == #"{"body":"PR #4 merged"}"#)
}

@Test func assignUsesAccountIdOnCloudAndNameOnDataCenter() throws {
  let me = AtlassianUser(id: "557058:abc", name: nil, displayName: "G")
  let c = try #require(JiraREST.assignRequest(cloud, key: "A-1", user: me, credential: .session))
  #expect(c.httpMethod == "PUT" && c.url?.path == "/rest/api/2/issue/A-1/assignee")
  #expect(String(decoding: c.httpBody ?? Data(), as: UTF8.self) == #"{"accountId":"557058:abc"}"#)
  let named = AtlassianUser(id: "JIRAUSER1", name: "gdas", displayName: "G")
  let d = try #require(JiraREST.assignRequest(dc, key: "A-1", user: named, credential: .session))
  #expect(String(decoding: d.httpBody ?? Data(), as: UTF8.self) == #"{"name":"gdas"}"#)
  let unnamed = AtlassianUser(id: "gdas", name: nil, displayName: "G")
  let e = try #require(JiraREST.assignRequest(dc, key: "A-1", user: unnamed, credential: .session))
  #expect(String(decoding: e.httpBody ?? Data(), as: UTF8.self) == #"{"name":"gdas"}"#)
}

@Test func failuresSayWhatHappened() {
  #expect(JiraREST.failure(status: 401, data: Data(), site: cloud, key: nil).message == "Signed out of acme.atlassian.net.")
  #expect(JiraREST.failure(status: 403, data: Data(), site: cloud, key: "A-1").message == "Jira says you can't do that.")
  #expect(JiraREST.failure(status: 404, data: Data(), site: cloud, key: "A-1").message == "A-1 isn't there anymore.")
  #expect(JiraREST.failure(status: 400, data: Data(#"{"errorMessages":["Bad JQL"]}"#.utf8), site: cloud, key: nil)
    .message == "Bad JQL")
  #expect(JiraREST.failure(status: 502, data: Data(), site: cloud, key: nil).message == "Jira answered 502.")
}
