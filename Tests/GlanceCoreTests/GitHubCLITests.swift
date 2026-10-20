import Foundation
import Testing
@testable import GlanceCore

private extension Result {
  var failureValue: Failure? {
    if case .failure(let failure) = self { return failure }
    return nil
  }
}

@Test func ghGetsGraphQLVariablesTyped() {
  #expect(GitHubCLI.graphQLArguments("query{viewer{login}}",
                                     variables: ["owner": .string("gobinda168"), "number": .int(51), "draft": .bool(true)])
    == ["api", "graphql", "-f", "query=query{viewer{login}}",
        "-F", "draft=true", "-F", "number=51", "-f", "owner=gobinda168"])
}

@Test func aRepositorySplitsIntoOwnerAndName() {
  #expect(GitHubCLI.split("gobinda168/glance")?.owner == "gobinda168")
  #expect(GitHubCLI.split("gobinda168/glance")?.name == "glance")
  #expect(GitHubCLI.split("glance") == nil)
  #expect(GitHubCLI.split("a/b/c") == nil)
  #expect(GitHubCLI.split("/glance") == nil)
}

@Test func ghFailuresComeFromItsExitStatusAndFirstLine() {
  #expect(GitHubCLI.outcome(status: 0, output: Data("[]".utf8), error: Data()) == .success(Data("[]".utf8)))
  #expect(GitHubCLI.outcome(status: 4, output: Data(), error: Data("To get started, run: gh auth login".utf8))
    == .failure(.signedOut))
  let refused = "GraphQL: Could not resolve to a PullRequest with the number of 999. (repository.pullRequest)\nmore"
  #expect(GitHubCLI.outcome(status: 1, output: Data(), error: Data(refused.utf8))
    == .failure(.failed("GraphQL: Could not resolve to a PullRequest with the number of 999. (repository.pullRequest)")))
  #expect(GitHubCLI.outcome(status: 1, output: Data(), error: Data()) == .failure(.failed("gh failed")))
}

@Test func ghGraphQLErrorsAreFailures() {
  if case .success(let data) = GitHubCLI.graphQLData(Data(#"{"data":{"viewer":{"login":"g"}}}"#.utf8)) {
    #expect((data["viewer"] as? [String: Any])?["login"] as? String == "g")
  } else {
    Issue.record("no data")
  }
  #expect(GitHubCLI.graphQLData(Data(#"{"errors":[{"message":"Field 'x' doesn't exist"}],"data":null}"#.utf8))
    .failureValue == .failed("Field 'x' doesn't exist"))
  #expect(GitHubCLI.graphQLData(Data("not json".utf8)).failureValue == .failed("GitHub sent something that isn't JSON"))
}

@Test func ghRunsAProgramWithItsInputAndReportsItsExit() {
  let echoed = GitHubCLI.execute("/bin/cat", [], input: Data("hello".utf8))
  #expect(echoed?.status == 0)
  #expect(echoed.map { String(decoding: $0.output, as: UTF8.self) } == "hello")
  let failed = GitHubCLI.execute("/bin/sh", ["-c", "echo oops >&2; exit 3"])
  #expect(failed?.status == 3)
  #expect(failed.map { String(decoding: $0.error, as: UTF8.self) } == "oops\n")
  #expect(GitHubCLI.execute("/no/such/program", []) == nil)
  #expect(GitHubCLI.run(nil, ["pr", "list"]) == .failure(.notInstalled))
  #expect(GitHubCLI.run("/bin/sh", ["-c", "echo signed out >&2; exit 4"]) == .failure(.signedOut))
}

@Test func manyProgramsAtOnceAllFinish() async {
  // Twice as many runs at once as the test pool has threads, each holding its thread until its program's stderr is
  // read: that stderr has to drain on threads of its own, or every run waits forever.
  let count = ProcessInfo.processInfo.activeProcessorCount * 2
  let finished = await withTaskGroup(of: Bool.self) { group in
    for _ in 0..<count {
      group.addTask { GitHubCLI.execute("/bin/sh", ["-c", "exec 1>&-; sleep 0.3; echo late >&2"])?.error == Data("late\n".utf8) }
    }
    var done = 0
    for await ok in group where ok { done += 1 }
    return done
  }
  #expect(finished == count)
}

@Test func failuresSayWhatToDo() {
  #expect(PullRequests.Failure.notInstalled.message == "Install the GitHub CLI: brew install gh")
  #expect(PullRequests.Failure.signedOut.message == "Sign in to GitHub from the Pull requests side bar.")
  #expect(PullRequests.Failure.notGitHub.message == "This project isn't on GitHub.")
  #expect(PullRequests.Failure.failed("HTTP 502").message == "HTTP 502")
}
