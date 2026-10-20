import Foundation
import Testing
@testable import GlanceCore

/// `gh pr checks 14148 --repo cli/cli --json …` (2026-08-15), trimmed to one check of each kind. The running and
/// cancelled rows and the commit status are shaped as gh writes them: Go's zero time for a time it doesn't have, as on
/// gobinda168/glance#3's queued jobs.
private let checksOutput = """
[{"bucket":"skipping","completedAt":"2026-08-15T05:12:30Z","description":"",
  "link":"https://github.com/cli/cli/actions/runs/31866377438/job/94968026024","name":"ready-for-review",
  "startedAt":"2026-08-15T05:12:30Z","state":"SKIPPED","workflow":"PR Triaging"},
 {"bucket":"pass","completedAt":"2026-08-15T04:59:00Z","description":"",
  "link":"https://github.com/cli/cli/runs/94966518720","name":"CodeQL",
  "startedAt":"2026-08-15T04:58:58Z","state":"SUCCESS","workflow":""},
 {"bucket":"fail","completedAt":"2026-08-15T04:59:49Z","description":"",
  "link":"https://github.com/cli/cli/actions/runs/31865758954/job/94966442733","name":"lint",
  "startedAt":"2026-08-15T04:58:16Z","state":"FAILURE","workflow":"Lint"},
 {"bucket":"pending","completedAt":"0001-01-01T00:00:00Z","description":"",
  "link":"https://github.com/cli/cli/actions/runs/31865758949/job/94966442609","name":"build (ubuntu-latest)",
  "startedAt":"2026-08-15T04:58:16Z","state":"IN_PROGRESS","workflow":"Unit and Integration Tests"},
 {"bucket":"cancel","completedAt":"2026-08-15T05:00:09Z","description":"",
  "link":"https://github.com/cli/cli/actions/runs/31865758949/job/94966442676",
  "name":"integration-tests (windows-latest)","startedAt":"2026-08-15T04:58:15Z","state":"CANCELLED",
  "workflow":"Unit and Integration Tests"},
 {"bucket":"pass","completedAt":"0001-01-01T00:00:00Z","description":"Deployment has completed",
  "link":"https://vercel.com/glance/glance/8xYzQ","name":"Vercel","startedAt":"0001-01-01T00:00:00Z",
  "state":"SUCCESS","workflow":""}]
"""

private func checks() throws -> [PullRequestChecks.Check] {
  try #require(PullRequestChecks.parse(Data(checksOutput.utf8)))
}

private func at(_ text: String) -> Date {
  try! Date(text, strategy: .iso8601)
}

@Test func readsEachCheckWithItsWorkflowTimesAndWhereItRan() throws {
  let all = try checks()
  #expect(all.map(\.name) == [
    "ready-for-review", "CodeQL", "lint", "build (ubuntu-latest)", "integration-tests (windows-latest)", "Vercel",
  ])
  let lint = all[2]
  #expect(lint.workflow == "Lint")
  #expect(lint.outcome == .failed)
  #expect(lint.startedAt == at("2026-08-15T04:58:16Z"))
  #expect(lint.completedAt == at("2026-08-15T04:59:49Z"))
  #expect(lint.source == .job(repository: "cli/cli", run: 31865758954, id: 94966442733))
  #expect(all[1].source == .checkRun(repository: "cli/cli", id: 94966518720))
  #expect(all[5].description == "Deployment has completed")
  #expect(all[5].source == .elsewhere(URL(string: "https://vercel.com/glance/glance/8xYzQ")!))
}

@Test func goZeroTimesAreNoTime() throws {
  let all = try checks()
  #expect(all[3].completedAt == nil)
  #expect(all[5].startedAt == nil)
  #expect(all[5].completedAt == nil)
}

@Test func bucketsBecomeOutcomesWithCancelledAsFailed() throws {
  #expect(try checks().map(\.outcome) == [.skipped, .passed, .failed, .running, .failed, .passed])
  #expect(PullRequestChecks.outcome(bucket: "something new") == .running)
}

@Test func somethingThatIsntAListIsNil() {
  #expect(PullRequestChecks.parse(Data(#"{"message":"Not Found"}"#.utf8)) == nil)
}

@Test func aBranchWithoutChecksIsAnEmptyListNotAFailure() {
  #expect(PullRequestChecks.isNoChecks(.failed("no checks reported on the 'feat/release' branch")))
  #expect(!PullRequestChecks.isNoChecks(.failed("HTTP 502: Bad Gateway")))
  #expect(!PullRequestChecks.isNoChecks(.signedOut))
}

@Test func aLinkSaysWhereACheckRan() {
  #expect(PullRequestChecks.source(link: "https://github.com/o/r/actions/runs/12/job/34?pr=5")
    == .job(repository: "o/r", run: 12, id: 34))
  #expect(PullRequestChecks.source(link: "https://github.com/o/r/runs/56") == .checkRun(repository: "o/r", id: 56))
  #expect(PullRequestChecks.source(link: "https://ci.example.com/build/7")
    == .elsewhere(URL(string: "https://ci.example.com/build/7")!))
  // Glance never opens github.com, so another page there is nothing to show.
  #expect(PullRequestChecks.source(link: "https://github.com/o/r/pull/5/checks") == .unknown)
  #expect(PullRequestChecks.source(link: "") == .unknown)
  #expect(PullRequestChecks.source(link: "not a link") == .unknown)
}

@Test func groupsGoFailingRunningPassingSkippedInGhsOrder() throws {
  let groups = PullRequestChecks.groups(try checks())
  #expect(groups.map(\.outcome) == [.failed, .running, .passed, .skipped])
  #expect(groups[0].checks.map(\.name) == ["lint", "integration-tests (windows-latest)"])
  #expect(groups[2].checks.map(\.name) == ["CodeQL", "Vercel"])
  #expect(PullRequestChecks.ordered(try checks()).map(\.name) == [
    "lint", "integration-tests (windows-latest)", "build (ubuntu-latest)", "CodeQL", "Vercel", "ready-for-review",
  ])
}

@Test func durationsReadLikeAClockAndNeverGoNegative() throws {
  let all = try checks()
  let now = at("2026-08-15T04:59:01Z")
  #expect(PullRequestChecks.duration(all[2], now: now) == "1m 33s")
  // Running: how long it's been running.
  #expect(PullRequestChecks.duration(all[3], now: now) == "45s")
  // Skipped (GitHub's times run backwards there), or never started.
  #expect(PullRequestChecks.duration(all[0], now: now) == nil)
  #expect(PullRequestChecks.duration(all[5], now: now) == nil)
  let long = PullRequestChecks.Check(name: "release", outcome: .passed, startedAt: at("2026-08-15T01:00:00Z"),
                                     completedAt: at("2026-08-15T03:05:59Z"))
  #expect(PullRequestChecks.duration(long, now: now) == "2h 5m")
  let backwards = PullRequestChecks.Check(name: "x", outcome: .failed, startedAt: at("2026-08-15T01:00:10Z"),
                                          completedAt: at("2026-08-15T01:00:00Z"))
  #expect(PullRequestChecks.duration(backwards, now: now) == nil)
}

@Test func aCheckFromThePagesRollupIsItsNameAndOutcome() {
  let check = PullRequestChecks.Check(PullRequestPage.Check(name: "build", outcome: .passed))
  #expect(check == PullRequestChecks.Check(name: "build", outcome: .passed))
  #expect(check.source == .unknown)
}

@Test func theListAsksGhForTheFieldsThePageShows() {
  #expect(PullRequestChecks.arguments(number: 51, repository: "gobinda168/glance") == [
    "pr", "checks", "51", "--repo", "gobinda168/glance", "--json",
    "name,state,bucket,link,workflow,description,startedAt,completedAt",
  ])
}
