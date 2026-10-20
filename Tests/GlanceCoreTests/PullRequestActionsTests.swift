import Foundation
import Testing
@testable import GlanceCore

private let repo = "gobinda168/glance"

@Test func mergingAsksGhWithTheChosenMethod() {
  #expect(PullRequestActions.merge(51, repository: repo, method: .squash)
    == ["pr", "merge", "51", "--repo", repo, "--squash"])
  #expect(PullRequestActions.merge(51, repository: repo, method: .rebase, auto: true)
    == ["pr", "merge", "51", "--repo", repo, "--rebase", "--auto"])
  #expect(PullRequestActions.disableAutoMerge(51, repository: repo) == ["pr", "merge", "51", "--repo", repo, "--disable-auto"])
}

@Test func theOtherWritesAreOneGhCommandEach() {
  #expect(PullRequestActions.markReady(51, repository: repo) == ["pr", "ready", "51", "--repo", repo])
  #expect(PullRequestActions.updateBranch(51, repository: repo) == ["pr", "update-branch", "51", "--repo", repo])
  #expect(PullRequestActions.checkout(51, repository: repo) == ["pr", "checkout", "51", "--repo", repo])
  #expect(PullRequestActions.close(51, repository: repo) == ["pr", "close", "51", "--repo", repo])
  #expect(PullRequestActions.diff(51, repository: repo) == ["pr", "diff", "51", "--repo", repo])
  #expect(PullRequestActions.comment(51, repository: repo) == ["pr", "comment", "51", "--repo", repo, "--body-file", "-"])
  #expect(PullRequestActions.editBody(51, repository: repo) == ["pr", "edit", "51", "--repo", repo, "--body-file", "-"])
  #expect(PullRequestActions.editTitle(51, repository: repo, title: "-v: Sparkle feed")
    == ["pr", "edit", "51", "--repo", repo, "--title=-v: Sparkle feed"])
  #expect(PullRequestActions.editBase(51, repository: repo, base: "release/1.0")
    == ["pr", "edit", "51", "--repo", repo, "--base=release/1.0"])
  #expect(PullRequestActions.editReviewers(51, repository: repo, add: ["mira-k", "devon"])
    == ["pr", "edit", "51", "--repo", repo, "--add-reviewer", "mira-k,devon"])
  #expect(PullRequestActions.editLabels(51, repository: repo, add: [], remove: ["build"])
    == ["pr", "edit", "51", "--repo", repo, "--remove-label", "build"])
}

@Test func readsTheRepositorysLabelsAndUsers() throws {
  #expect(PullRequestActions.labelList(repository: repo)
    == ["label", "list", "--repo", repo, "--json", "name,color", "--limit", "200"])
  #expect(PullRequestActions.parseLabels(Data(#"[{"name":"release","color":"e8643c"},{"name":"build","color":"ededed"}]"#.utf8))
    == [.init(name: "release", color: "e8643c"), .init(name: "build", color: "ededed")])
  #expect(PullRequestActions.parseLabels(Data("{}".utf8)) == nil)
  let users = try #require(PullRequestActions.assignableUsersArguments(repository: repo))
  #expect(users.contains("owner=gobinda168"))
  #expect(PullRequestActions.parseAssignableUsers(Data(
    #"{"data":{"repository":{"assignableUsers":{"nodes":[{"login":"gobinda168"},{"login":"mira-k"}]}}}}"#.utf8))
    == ["gobinda168", "mira-k"])
}

@Test func readsIssuesForLinksAndSearches() throws {
  #expect(PullRequestActions.issueView(12, repository: repo)
    == ["issue", "view", "12", "--repo", repo, "--json", "number,title,state,body,author,createdAt"])
  let issue = try #require(PullRequestActions.parseIssue(Data("""
    {"number":12,"title":"Sparkle can't find the feed","state":"OPEN","body":"Steps…",
     "author":{"login":"devon"},"createdAt":"2026-10-05T09:00:00Z"}
    """.utf8)))
  #expect(issue == .init(number: 12, title: "Sparkle can't find the feed", state: "OPEN", body: "Steps…",
                         author: "devon", createdAt: Date(timeIntervalSince1970: 1_791_190_800)))
  #expect(PullRequestActions.issueSearch("sparkle feed", repository: repo)
    == ["issue", "list", "--repo", repo, "--search", "sparkle feed", "--state", "all",
        "--json", "number,title,state", "--limit", "8"])
  #expect(PullRequestActions.parseIssues(Data(#"[{"number":12,"title":"Feed","state":"CLOSED"}]"#.utf8))
    == [.init(number: 12, title: "Feed", state: "CLOSED", body: "", author: "", createdAt: nil)])
}

@Test func linkingAnIssueAddsClosesToTheDescription() {
  #expect(PullRequestActions.body("", closing: 12) == "Closes #12")
  #expect(PullRequestActions.body("## What\n- builds\n", closing: 12) == "## What\n- builds\n\nCloses #12")
  #expect(PullRequestActions.body("Fixes #12 for good.", closing: 12) == "Fixes #12 for good.")
  #expect(PullRequestActions.body("resolved #12", closing: 12) == "resolved #12")
  #expect(PullRequestActions.body("Closes #123", closing: 12) == "Closes #123\n\nCloses #12")
}

@Test func aNumberThatIsAnIssueIsntAPullRequest() {
  #expect(PullRequestActions.isNotAPullRequest(
    .failed("GraphQL: Could not resolve to a PullRequest with the number of 12. (repository.pullRequest)")))
  #expect(!PullRequestActions.isNotAPullRequest(.failed("HTTP 502")))
  #expect(!PullRequestActions.isNotAPullRequest(.signedOut))
}

@Test func readsTheRepositorysBranchesForTheBasePicker() {
  #expect(PullRequestActions.branchList(repository: repo)
    == ["api", "repos/\(repo)/branches?per_page=100", "--paginate", "--jq", ".[].name"])
  #expect(PullRequestActions.parseBranches(Data("main\nfeat/release\n\nrelease/1.0\n".utf8))
    == ["main", "feat/release", "release/1.0"])
  let branches = ["feat/release", "release/10", "main", "release/2", "develop", "main"]
  // The current base first, then by name (numbers in order); never the pull request's own branch.
  #expect(PullRequestActions.baseChoices(branches, head: "feat/release", base: "main", filter: "")
    == ["main", "develop", "release/2", "release/10"])
  #expect(PullRequestActions.baseChoices(branches, head: "feat/release", base: "main", filter: " REL ")
    == ["release/2", "release/10"])
}
