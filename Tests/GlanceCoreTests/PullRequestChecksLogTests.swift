import Foundation
import Testing
@testable import GlanceCore

/// `gh run view 31865758954 --repo cli/cli --log-failed --job 94966442733` (2026-08-15), trimmed. gh couldn't tell
/// the job's steps apart, so it printed the whole job as "UNKNOWN STEP": a byte-order mark on the first line,
/// colours in the tool's output, and the post-job cleanup after the error.
private let unknownStepLog = [
  "lint\tUNKNOWN STEP\t\u{FEFF}2026-08-15T04:58:17.6242918Z Current runner version: '2.336.0'",
  "lint\tUNKNOWN STEP\t2026-08-15T04:58:17.6268717Z ##[group]Runner Image Provisioner",
  "lint\tUNKNOWN STEP\t2026-08-15T04:58:17.6274024Z ##[endgroup]",
  "lint\tUNKNOWN STEP\t2026-08-15T04:58:40.9538541Z ##[group]Run golangci/golangci-lint-action@ba0d7d2",
  "lint\tUNKNOWN STEP\t2026-08-15T04:58:40.9544930Z ##[endgroup]",
  "lint\tUNKNOWN STEP\t2026-08-15T04:58:43.8897426Z ##[group]run golangci-lint",
  "lint\tUNKNOWN STEP\t2026-08-15T04:59:45.1041210Z \u{1B}[31mgo.mod:70:1\u{1B}[0m: replacement are not allowed",
  "lint\tUNKNOWN STEP\t2026-08-15T04:59:45.1042778Z 1 issues:",
  "lint\tUNKNOWN STEP\t2026-08-15T04:59:45.1043148Z ",
  "lint\tUNKNOWN STEP\t2026-08-15T04:59:45.1065166Z ##[error]issues found",
  "lint\tUNKNOWN STEP\t2026-08-15T04:59:45.1074939Z ##[endgroup]",
  "lint\tUNKNOWN STEP\t2026-08-15T04:59:45.1252707Z Post job cleanup.",
  "lint\tUNKNOWN STEP\t2026-08-15T04:59:47.3465302Z Cleaning up orphan processes",
].joined(separator: "\n") + "\n"

/// The same command when gh knows the steps: only the failed ones, each line under its step's name.
private let stepLog = [
  "test\tLint\t2026-10-06T10:00:00.0000000Z ##[error]swiftlint found 2 warnings",
  "test\tRun swift test\t2026-10-06T10:00:01.0000000Z ##[group]Run swift test",
  "test\tRun swift test\t2026-10-06T10:00:01.1000000Z \u{1B}[36;1mswift test\u{1B}[0m",
  "test\tRun swift test\t2026-10-06T10:00:02.0000000Z ##[endgroup]",
  "test\tRun swift test\t2026-10-06T10:01:00.0000000Z ✘ Test aThreadWaitsOnYou() failed",
  "test\tRun swift test\t2026-10-06T10:01:00.5000000Z ##[error]Process completed with exit code 1.",
].joined(separator: "\n")

@Test func withoutStepsTheLogEndsAtItsLastErrorNotTheCleanup() throws {
  let log = try #require(PullRequestChecks.log(unknownStepLog))
  #expect(log.step == "golangci/golangci-lint-action@ba0d7d2")
  #expect(log.lines.map(\.text) == [
    "Current runner version: '2.336.0'", "Runner Image Provisioner", "Run golangci/golangci-lint-action@ba0d7d2",
    "run golangci-lint", "go.mod:70:1: replacement are not allowed", "1 issues:", "", "issues found",
  ])
  #expect(log.lines.map(\.isError) == [false, false, false, false, false, false, false, true])
  #expect(log.omitted == 0)
}

@Test func onlyTheLastLinesAreKept() throws {
  let log = try #require(PullRequestChecks.log(unknownStepLog, keep: 3))
  #expect(log.lines.map(\.text) == ["1 issues:", "", "issues found"])
  #expect(log.omitted == 5)
  // The step's header is above the kept lines; it still names the step.
  #expect(log.step == "golangci/golangci-lint-action@ba0d7d2")
}

@Test func withStepsItIsTheLastFailedStepUnderGhsName() throws {
  let log = try #require(PullRequestChecks.log(stepLog))
  #expect(log.step == "Run swift test")
  #expect(log.lines.map(\.text) == [
    "Run swift test", "swift test", "✘ Test aThreadWaitsOnYou() failed", "Process completed with exit code 1.",
  ])
  #expect(log.lines.last?.isError == true)
}

@Test func aLogWithoutAnErrorShowsItsEnd() throws {
  let output = "build\tUNKNOWN STEP\t2026-10-06T10:00:00Z one\nbuild\tUNKNOWN STEP\t2026-10-06T10:00:01Z two\n"
  let log = try #require(PullRequestChecks.log(output, keep: 1))
  #expect(log.lines.map(\.text) == ["two"])
  #expect(log.omitted == 1)
  #expect(log.step == "")
}

@Test func noLogIsNil() {
  #expect(PullRequestChecks.log("") == nil)
  #expect(PullRequestChecks.log("failed to get run log: log not found\n") == nil)
}

@Test func aCheckRunsTitleAndSummary() throws {
  let json = #"{"id":94966518720,"name":"CodeQL","conclusion":"success","output":{"#
    + #""title":"No new alerts in code changed by this pull request","#
    + #""summary":"[View all branch alerts](/cli/cli/security/code-scanning).","text":""}}"#
  let output = try #require(PullRequestChecks.parseOutput(Data(json.utf8)))
  #expect(output.title == "No new alerts in code changed by this pull request")
  #expect(output.summary == "[View all branch alerts](/cli/cli/security/code-scanning).")
  #expect(PullRequestChecks.parseOutput(Data(#"{"id":1,"output":{"title":null,"summary":null}}"#.utf8))
    == PullRequestChecks.Output(title: "", summary: ""))
  #expect(PullRequestChecks.parseOutput(Data(#"{"message":"Not Found"}"#.utf8)) == nil)
}

@Test func ghCommandsForTheLogTheRerunAndTheSummary() {
  #expect(PullRequestChecks.logArguments(repository: "cli/cli", run: 31865758954, job: 94966442733) == [
    "run", "view", "31865758954", "--repo", "cli/cli", "--log-failed", "--job", "94966442733",
  ])
  #expect(PullRequestChecks.rerunArguments(repository: "cli/cli", run: 31865758954) == [
    "run", "rerun", "31865758954", "--repo", "cli/cli", "--failed",
  ])
  #expect(PullRequestChecks.checkRunArguments(repository: "cli/cli", id: 94966518720) == [
    "api", "repos/cli/cli/check-runs/94966518720",
  ])
}
