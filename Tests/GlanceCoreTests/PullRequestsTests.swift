import Foundation
import Testing
@testable import GlanceCore

private let listOutput = """
[
  {
    "number": 51, "title": "Release: build, sign, appcast and DMG", "author": {"login": "gobinda168", "is_bot": false},
    "isDraft": false, "headRefName": "feat/release", "baseRefName": "main", "additions": 147, "deletions": 0,
    "changedFiles": 19, "reviewDecision": "CHANGES_REQUESTED", "mergeable": "MERGEABLE",
    "url": "https://github.com/gobinda168/glance/pull/51", "mergedAt": null,
    "statusCheckRollup": [
      {"__typename": "CheckRun", "name": "swift test", "status": "COMPLETED", "conclusion": "SUCCESS"},
      {"__typename": "CheckRun", "name": "lint", "status": "COMPLETED", "conclusion": "SKIPPED"},
      {"__typename": "CheckRun", "name": "sign", "status": "COMPLETED", "conclusion": "FAILURE"},
      {"__typename": "CheckRun", "name": "dmg", "status": "IN_PROGRESS", "conclusion": ""},
      {"__typename": "StatusContext", "context": "ci/legacy", "state": "PENDING"}
    ]
  },
  {
    "number": 49, "title": "Version stamping in both apps", "author": {"login": "gobinda168"}, "isDraft": true,
    "headRefName": "feat/version", "baseRefName": "main", "additions": 3, "deletions": 1, "changedFiles": 2,
    "reviewDecision": "", "mergeable": "CONFLICTING", "url": "https://github.com/gobinda168/glance/pull/49",
    "mergedAt": "0001-01-01T00:00:00Z", "statusCheckRollup": []
  },
  {
    "number": 47, "title": "Sparkle updates", "author": {"login": "gobinda168"}, "reviewDecision": "APPROVED",
    "mergeable": "UNKNOWN", "mergedAt": "2026-10-05T18:12:44Z"
  },
  {"title": "no number, so not a pull request"}
]
"""

@Test func readsTheListsGhPrints() throws {
  let pullRequests = try #require(PullRequests.parse(Data(listOutput.utf8)))
  #expect(pullRequests == [
    .init(number: 51, title: "Release: build, sign, appcast and DMG", author: "gobinda168", head: "feat/release",
          base: "main", additions: 147, changedFiles: 19, review: .changesRequested,
          checks: .init(passed: 2, failed: 1, pending: 2), mergeable: .mergeable,
          url: "https://github.com/gobinda168/glance/pull/51"),
    .init(number: 49, title: "Version stamping in both apps", author: "gobinda168", isDraft: true, head: "feat/version",
          base: "main", additions: 3, deletions: 1, changedFiles: 2, mergeable: .conflicting,
          url: "https://github.com/gobinda168/glance/pull/49"),
    .init(number: 47, title: "Sparkle updates", author: "gobinda168", review: .approved,
          mergedAt: Date(timeIntervalSince1970: 1_791_223_964)),
  ])
  #expect(PullRequests.parse(Data("[]".utf8)) == [])
  #expect(PullRequests.parse(Data("{\"message\": \"Not Found\"}".utf8)) == nil)
  #expect(PullRequests.parse(Data("[{\"number\": 1, \"ti".utf8)) == nil)
}

@Test func countsChecksAsGitHubDoes() {
  let rollup: [[String: Any]] = [
    ["status": "COMPLETED", "conclusion": "SUCCESS"], ["status": "COMPLETED", "conclusion": "NEUTRAL"],
    ["status": "COMPLETED", "conclusion": "SKIPPED"], ["status": "COMPLETED", "conclusion": "CANCELLED"],
    ["status": "COMPLETED", "conclusion": "TIMED_OUT"], ["status": "QUEUED"], ["status": "IN_PROGRESS"],
    ["state": "SUCCESS"], ["state": "ERROR"], ["state": "EXPECTED"],
  ]
  let checks = PullRequests.Checks(rollup: rollup)
  #expect(checks == .init(passed: 4, failed: 3, pending: 3))
  #expect(checks.summary == "4/10")
  #expect(checks.state == .failing)
  #expect(PullRequests.Checks(passed: 3, pending: 1).state == .pending)
  #expect(PullRequests.Checks(passed: 14).state == .passing)
  #expect(PullRequests.Checks(passed: 14).summary == "14/14")
  #expect(PullRequests.Checks().state == .empty)
  #expect(PullRequests.Checks().summary == nil)
}

@Test func asksGhForEachListOfTheSideBar() {
  let common = ["pr", "list", "--repo", "o/r", "--json", PullRequests.fields]
  #expect(PullRequests.arguments(.waitingOnYou, repository: "o/r")
    == common + ["--state", "open", "--search", "review-requested:@me", "--limit", "30"])
  #expect(PullRequests.arguments(.yours, repository: "o/r") == common + ["--state", "open", "--author", "@me", "--limit", "30"])
  #expect(PullRequests.arguments(.recentlyMerged, repository: "o/r")
    == common + ["--state", "merged", "--author", "@me", "--limit", "5"])
}

@Test func showsTheNewestMergeFirst() {
  let older = PullRequests.PullRequest(number: 1, title: "older", mergedAt: Date(timeIntervalSince1970: 1_000))
  let newer = PullRequests.PullRequest(number: 2, title: "newer", mergedAt: Date(timeIntervalSince1970: 2_000))
  let board = PullRequests.Board(repository: "o/r", waitingOnYou: [], yours: [], recentlyMerged: [older, newer])
  #expect(board.recentlyMerged.map(\.number) == [2, 1])
  #expect(board.repository == "o/r")
}

@Test func listsWhatBlocksAMergeWorstFirst() {
  let stuck = PullRequests.PullRequest(number: 1, title: "t", isDraft: true, review: .required,
                                       checks: .init(passed: 1, failed: 1, pending: 2), mergeable: .conflicting)
  #expect(PullRequests.blockers(stuck) == [.draft, .conflicts, .checksFailing(1), .checksPending(2), .reviewRequired])
  #expect(PullRequests.blockers(stuck).filter(\.isHard) == [.draft, .conflicts, .checksFailing(1)])
  let ready = PullRequests.PullRequest(number: 2, title: "t", review: .approved, checks: .init(passed: 3), mergeable: .mergeable)
  #expect(PullRequests.blockers(ready) == [])
  #expect(PullRequests.blockers(.init(number: 3, title: "t", review: .changesRequested)) == [.changesRequested])
}

@Test func describesEachRowUnderItsTitle() {
  let release = PullRequests.PullRequest(number: 51, title: "t", author: "mira-k", head: "feat/release", base: "main")
  #expect(PullRequests.subline(release, in: .waitingOnYou) == "#51 · mira-k · review requested")
  #expect(PullRequests.subline(release, in: .yours) == "#51 · feat/release → main")
  #expect(PullRequests.subline(release, in: .recentlyMerged) == "#51 · merged")
  #expect(PullRequests.subline(.init(number: 49, title: "t", isDraft: true), in: .yours) == "#49 · draft")
  #expect(PullRequests.subline(.init(number: 50, title: "t", review: .changesRequested), in: .yours)
    == "#50 · changes requested")
}

@Test func filtersRowsByTitleAuthorOrNumber() {
  let release = PullRequests.PullRequest(number: 51, title: "Release: build, sign", author: "mira-k")
  #expect(PullRequests.matches(release, filter: ""))
  #expect(PullRequests.matches(release, filter: "   "))
  #expect(PullRequests.matches(release, filter: "SIGN"))
  #expect(PullRequests.matches(release, filter: "mira"))
  #expect(PullRequests.matches(release, filter: "#5"))
  #expect(PullRequests.matches(release, filter: "51"))
  #expect(!PullRequests.matches(release, filter: "#52"))
  #expect(!PullRequests.matches(release, filter: "devon"))
}

@Test func findsTheRepositoryOfAGitHubRemote() {
  let urls = [
    "https://github.com/gobinda168/glance.git", "https://github.com/gobinda168/glance", "https://github.com/gobinda168/glance/",
    "git@github.com:gobinda168/glance.git", "ssh://git@github.com/gobinda168/glance.git",
    "ssh://git@github.com:22/gobinda168/glance.git", "https://x-access-token:abc@github.com/gobinda168/glance.git",
  ]
  for url in urls {
    #expect(PullRequests.repository(remoteURL: url) == "gobinda168/glance", "\(url)")
  }
  #expect(PullRequests.repository(remoteURL: "https://gitlab.com/o/r.git") == nil)
  #expect(PullRequests.repository(remoteURL: "/Users/me/glance") == nil)
  #expect(PullRequests.repository(remoteURL: "https://github.com/onlyowner") == nil)
}

@Test func prefersUpstreamThenGithubThenOriginAsGhDoes() {
  let remotes = """
  fork\thttps://github.com/me/glance.git (fetch)
  fork\thttps://github.com/me/glance.git (push)
  origin\tgit@github.com:gobinda168/glance.git (fetch)
  origin\tgit@github.com:gobinda168/glance.git (push)
  """
  #expect(PullRequests.repository(remotes: remotes) == "gobinda168/glance")
  #expect(PullRequests.repository(remotes: remotes + "\nupstream\thttps://github.com/team/glance.git (fetch)") == "team/glance")
  #expect(PullRequests.repository(remotes: "fork\thttps://github.com/me/glance.git (fetch)") == "me/glance")
  #expect(PullRequests.repository(remotes: "origin\thttps://gitlab.com/o/r.git (fetch)") == nil)
  #expect(PullRequests.repository(remotes: "") == nil)
}

@Test func findsGhWhereInstallersPutIt() {
  #expect(PullRequests.executable(home: "/Users/me", isExecutable: { $0 == "/usr/local/bin/gh" }) == "/usr/local/bin/gh")
  #expect(PullRequests.executable(home: "/Users/me", isExecutable: { $0 == "/Users/me/.local/bin/gh" || $0 == "/opt/homebrew/bin/gh" })
    == "/opt/homebrew/bin/gh")
  #expect(PullRequests.executable(home: "/Users/me", isExecutable: { $0 == "/Users/me/.local/bin/gh" }) == "/Users/me/.local/bin/gh")
  #expect(PullRequests.executable(home: "/Users/me", isExecutable: { _ in false }) == nil)
}

@Test func listsEveryGitHubRepositoryAmongTheRemotesOnceInGhsOrder() {
  let remotes = """
  origin\tgit@github.com:me/ghostty.git (fetch)
  origin\tgit@github.com:me/ghostty.git (push)
  upstream\thttps://github.com/ghostty-org/ghostty.git (fetch)
  upstream\thttps://github.com/ghostty-org/ghostty.git (push)
  mirror\thttps://gitlab.com/me/ghostty.git (fetch)
  backup\thttps://github.com/Me/Ghostty.git (fetch)
  """
  #expect(PullRequests.repositories(remotes: remotes) == ["ghostty-org/ghostty", "me/ghostty"])
  #expect(PullRequests.repositories(remotes: "") == [])
}

@Test func theBoardOfARepositoryNeedsGhAndSaysWhenItIsSignedOut() throws {
  #expect(PullRequests.board(repository: "o/r", gh: nil) == .failure(.notInstalled))
  let signedOut = try fakeGh("echo 'To get started with GitHub CLI, please run:  gh auth login' >&2; exit 4")
  defer { try? FileManager.default.removeItem(atPath: signedOut) }
  #expect(PullRequests.board(repository: "o/r", gh: signedOut) == .failure(.signedOut))
}

@Test func theBoardOfARepositoryKeepsItsName() throws {
  let empty = try fakeGh("echo '[]'")
  defer { try? FileManager.default.removeItem(atPath: empty) }
  #expect(PullRequests.board(repository: "Gobinda168/Glance", gh: empty)
    == .success(PullRequests.Board(repository: "Gobinda168/Glance", waitingOnYou: [], yours: [], recentlyMerged: [])))
}

@Test func theSideBarShowsThePickElseTheTabsProject() {
  #expect(PullRequests.shownRepository(picked: "a/b", tabProject: "c/d") == "a/b")
  #expect(PullRequests.shownRepository(picked: nil, tabProject: "c/d") == "c/d")
  #expect(PullRequests.shownRepository(picked: nil, tabProject: nil) == nil)
}

/// An executable shell script standing in for gh, whatever its arguments.
private func fakeGh(_ body: String) throws -> String {
  let path = FileManager.default.temporaryDirectory.appendingPathComponent("gh-\(UUID().uuidString)").path
  try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
  return path
}

private let accountOutput = """
{"data": {
  "waiting": {"nodes": [
    {"number": 412, "title": "Fix token cache", "isDraft": false, "url": "https://github.com/acme/api/pull/412",
     "headRefName": "fix/cache", "baseRefName": "main", "additions": 12, "deletions": 3, "changedFiles": 2,
     "reviewDecision": "REVIEW_REQUIRED", "mergeable": "MERGEABLE", "mergedAt": null, "author": {"login": "mira-k"},
     "repository": {"nameWithOwner": "acme/api"},
     "commits": {"nodes": [{"commit": {"statusCheckRollup": {"contexts": {"nodes": [
       {"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "FAILURE"},
       {"__typename": "StatusContext", "state": "SUCCESS"}]}}}}]}}
  ]},
  "yours": {"nodes": [
    {"number": 31, "title": "Docs: setup", "isDraft": true, "url": "u", "headRefName": "docs", "baseRefName": "main",
     "additions": 1, "deletions": 0, "changedFiles": 1, "reviewDecision": null, "mergeable": "UNKNOWN",
     "mergedAt": null, "author": {"login": "me"}, "repository": {"nameWithOwner": "me/glance"},
     "commits": {"nodes": [{"commit": {"statusCheckRollup": null}}]}},
    {}
  ]},
  "merged": {"nodes": [
    {"number": 3, "title": "Old", "isDraft": false, "url": "u", "headRefName": "a", "baseRefName": "main",
     "additions": 0, "deletions": 0, "changedFiles": 0, "reviewDecision": "APPROVED", "mergeable": "UNKNOWN",
     "mergedAt": "2026-10-01T10:00:00Z", "author": {"login": "me"}, "repository": {"nameWithOwner": "me/glance"},
     "commits": {"nodes": []}}
  ]}
}}
"""

@Test func theAccountBoardReadsEveryRepository() throws {
  let board = try #require(PullRequests.parseAccount(Data(accountOutput.utf8)))
  #expect(board.repository == PullRequests.allRepositories)
  #expect(board.waitingOnYou.map(\.number) == [412])
  #expect(board.waitingOnYou[0].repository == "acme/api")
  #expect(board.waitingOnYou[0].checks == PullRequests.Checks(passed: 1, failed: 1, pending: 0))
  #expect(board.waitingOnYou[0].author == "mira-k")
  #expect(board.recentlyMerged.map(\.number) == [3])
}

@Test func accountRowsWithoutChecksStillParse() throws {
  let board = try #require(PullRequests.parseAccount(Data(accountOutput.utf8)))
  // The empty node {} isn't a pull request; #31 has statusCheckRollup null.
  #expect(board.yours.map(\.number) == [31])
  #expect(board.yours[0].checks == PullRequests.Checks())
  #expect(board.yours[0].review == .undecided)
}

@Test func theAccountBoardIsOneGraphQLCall() {
  let arguments = PullRequests.accountArguments()
  #expect(Array(arguments.prefix(2)) == ["api", "graphql"])
  #expect(arguments.contains("waiting=is:pr is:open archived:false review-requested:@me sort:updated-desc"))
  #expect(arguments.contains("yours=is:pr is:open archived:false author:@me sort:updated-desc"))
  #expect(arguments.contains("merged=is:pr is:merged author:@me sort:updated-desc"))
  #expect(PullRequests.accountQuery.contains("first: 5"))
  #expect(PullRequests.parseAccount(Data("{\"errors\": []}".utf8)) == nil)
  #expect(PullRequests.accountBoard(gh: nil) == .failure(.notInstalled))
}

@Test func aRepositorysBoardRowsCarryItsName() {
  let rows = PullRequests.parse(Data(listOutput.utf8), repository: "gobinda168/glance") ?? []
  #expect(!rows.isEmpty)
  #expect(rows.allSatisfy { $0.repository == "gobinda168/glance" })
}

@Test func allRepositoriesSublinesStartWithTheRepository() {
  let row = PullRequests.PullRequest(number: 48, title: "t", author: "mira-k", repository: "acme/api")
  #expect(PullRequests.subline(row, in: .waitingOnYou, showsRepository: true) == "api · #48 · mira-k · review requested")
  #expect(PullRequests.subline(row, in: .waitingOnYou) == "#48 · mira-k · review requested")
}
