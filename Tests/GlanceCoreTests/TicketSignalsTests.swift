import Foundation
import Testing
@testable import GlanceCore

private let now = Date(timeIntervalSince1970: 1_760_000_000)
private let hour: TimeInterval = 3_600
private let abc = Ticket(tracker: "jira", key: "ABC-123", title: "Login", status: "To Do", statusCategory: .todo,
                         transitions: [], group: .assigned)

@Test func commitsAndBranchesSuggestInProgressOncePerTicket() {
  let commits = [TicketSignals.Commit(hash: "a1b2c3d4e5", subject: "ABC-123 wire login", repository: nil,
                                      date: now - hour),
                 TicketSignals.Commit(hash: "f6", subject: "ABC-123 tests", repository: nil, date: now - 2 * hour)]
  let branches = [TicketSignals.Branch(name: "abc-123-login", repository: "acme/api", date: now - 3 * hour)]
  let found = TicketSignals.git(commits: commits, branches: branches, tickets: [abc], now: now)
  #expect(found.count == 1)
  #expect(found[0].signal == .git && found[0].target == .inProgress)
  #expect(found[0].evidence == "Commit a1b2c3d · ABC-123 wire login")
  #expect(found[0].evidenceID == "commit:a1b2c3d4e5")
}

@Test func onlyRecentActivityCounts() {
  let old = [TicketSignals.Commit(hash: "x", subject: "ABC-123", repository: nil, date: now - 3 * 86_400)]
  #expect(TicketSignals.git(commits: old, branches: [], tickets: [abc], now: now).isEmpty)
  let pr = TicketSignals.PullRequest(repository: "acme/api", number: 4, title: "ABC-123", body: "", branch: "x",
                                     url: nil, state: .merged, date: now - 3 * 86_400)
  #expect(TicketSignals.pullRequests([pr], tickets: [abc], now: now).isEmpty)
}

@Test func aMergedPullRequestWinsOverAnOpenOne() {
  let opened = TicketSignals.PullRequest(repository: "acme/api", number: 412, title: "Login flow", body: "Closes ABC-123",
                                         branch: "feature/x", url: URL(string: "https://github.com/acme/api/pull/412"),
                                         state: .open, date: now - hour)
  var merged = opened
  merged.state = .merged
  merged.date = now - 2 * hour
  let found = TicketSignals.pullRequests([opened, merged], tickets: [abc], now: now)
  #expect(found.count == 1)
  #expect(found[0].signal == .prMerged && found[0].target == .done)
  #expect(found[0].evidence == "PR #412 merged · Login flow")
  #expect(found[0].evidenceID == "pr:acme/api#412:merged")
  #expect(found[0].link?.absoluteString == "https://github.com/acme/api/pull/412")
  let onlyOpen = TicketSignals.pullRequests([opened], tickets: [abc], now: now)
  #expect(onlyOpen.first?.signal == .prOpened && onlyOpen.first?.target == .review)
}

@Test func aQuietInProgressTicketGoesStale() {
  var working = abc
  working.statusCategory = .inProgress
  working.updated = now - 5 * 86_400
  let stale = TicketSignals.stale(tickets: [working], activity: [:], now: now, days: 3)
  #expect(stale.count == 1 && stale[0].target == nil && stale[0].evidence == "No activity for 5 days")
  #expect(TicketSignals.stale(tickets: [working], activity: [working.id: now - hour], now: now, days: 3).isEmpty)
  #expect(TicketSignals.stale(tickets: [abc], activity: [:], now: now, days: 3).isEmpty)
  var unknownAge = working
  unknownAge.updated = nil
  #expect(TicketSignals.stale(tickets: [unknownAge], activity: [:], now: now, days: 3).isEmpty)
}

@Test func aSessionNamingATicketSuggestsInProgress() {
  let found = TicketSignals.session(prompts: ["let's do ABC-123 today", "and the tests"], branch: "main",
                                    repository: nil, file: "/t/s.jsonl", tickets: [abc], at: now)
  #expect(found.map(\.ticketID) == [abc.id])
  #expect(found[0].signal == .session && found[0].evidenceID == "session:/t/s.jsonl")
  #expect(found[0].evidence == "Claude session · let's do ABC-123 today")
  #expect(TicketSignals.session(prompts: [], branch: "abc-123-x", repository: nil, file: "f", tickets: [abc],
                                at: now).count == 1)
}

@Test func branchesAndPullRequestsParse() throws {
  let output = "abc-123-login\u{1f}2026-10-09T10:00:00+05:30\nmain\u{1f}2026-10-01T09:00:00+05:30\nbroken line\n"
  let branches = TicketSignals.branches(output, repository: "acme/api")
  #expect(branches.map(\.name) == ["abc-123-login", "main"])
  let data: [String: Any] = [
    "open": ["nodes": [["number": 412, "title": "Login", "body": "Closes ABC-123", "url": "https://github.com/acme/api/pull/412",
                        "headRefName": "abc-123", "createdAt": "2026-10-09T08:00:00Z", "mergedAt": NSNull(),
                        "repository": ["nameWithOwner": "acme/api"]]]],
    "merged": ["nodes": [["number": 400, "title": "Old", "body": "", "url": "https://github.com/acme/api/pull/400",
                          "headRefName": "x", "createdAt": "2026-10-01T08:00:00Z", "mergedAt": "2026-10-08T08:00:00Z",
                          "repository": ["nameWithOwner": "acme/api"]], [:]]],
  ]
  let prs = TicketSignals.pullRequests(from: data)
  #expect(prs.map(\.number) == [412, 400])
  #expect(prs[0].state == .open && prs[1].state == .merged)
  #expect(prs[1].date == TicketPrompts.date("2026-10-08T08:00:00Z"))
  #expect(TicketSignals.pullRequestArguments(now: now).contains { $0.contains("author:@me") })
}

@Test func foldersMapToTheirRepository() {
  let folders = ["acme/api": "/Users/me/Code/api", "acme/apigw": "/Users/me/Code/api-gw"]
  #expect(TicketSignals.repository(for: "/Users/me/Code/api/Sources", in: folders) == "acme/api")
  #expect(TicketSignals.repository(for: "/Users/me/Code/api-gw", in: folders) == "acme/apigw")
  #expect(TicketSignals.repository(for: "/Users/me/Code/other", in: folders) == nil)
}
