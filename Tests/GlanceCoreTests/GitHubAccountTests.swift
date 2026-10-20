import Foundation
import Testing
@testable import GlanceCore

@Test func signInRunsGhsBrowserFlowWithoutTouchingTheGitProtocol() {
  #expect(GitHubAccount.signInArguments == ["auth", "login", "--web", "--hostname", "github.com"])
  #expect(!GitHubAccount.signInArguments.contains("--git-protocol"))
  #expect(GitHubAccount.signOutArguments(login: "gobinda168")
    == ["auth", "logout", "--hostname", "github.com", "--user", "gobinda168"])
  #expect(GitHubAccount.loginArguments == ["api", "user", "--jq", ".login"])
}

@Test func readsTheCodeAndThePageInEitherWording() throws {
  // gh 2.101 without a terminal (2026-10-08).
  let copied = """
  ! One-time code (AB12-CD34) copied to clipboard
  Open this URL to continue in your web browser: https://github.com/login/device
  """
  let device = try #require(URL(string: "https://github.com/login/device"))
  #expect(GitHubAccount.signInPrompt(copied) == GitHubAccount.SignInPrompt(code: "AB12-CD34", url: device))
  // gh's other wording.
  let first = "! First copy your one-time code: WXYZ-9876\n"
    + "Open this URL to continue in your web browser: https://github.com/login/device\n"
  #expect(GitHubAccount.signInPrompt(first)?.code == "WXYZ-9876")
}

@Test func theCodeIsntThereUntilBothLinesHaveCome() {
  #expect(GitHubAccount.signInPrompt("") == nil)
  #expect(GitHubAccount.signInPrompt("! One-time code (AB12-CD34) copied to clipboard\n") == nil)
  #expect(GitHubAccount.signInPrompt("Open this URL to continue in your web browser: https://github.com/login/device")
    == nil)
  // A code-shaped word on a line that isn't about the code.
  #expect(GitHubAccount.signInPrompt("Branch AB12-CD34\nOpen this URL: https://github.com/login/device") == nil)
}

@Test func theLastLineSaysWhyASignInFailed() {
  #expect(GitHubAccount.lastLine("! One-time code (AB12-CD34) copied\nerror: expired_token\n\n") == "error: expired_token")
  #expect(GitHubAccount.lastLine("  \n") == nil)
}

@Test func listsTheAccountsRepositoriesNewestPushFirstWithoutArchivedOnes() throws {
  let output = """
  gobinda168/glance\ttrue\tfalse\t2026-10-08T05:41:23Z
  gobinda168/old\tfalse\ttrue\t2026-10-01T00:00:00Z
  acme/api\ttrue\tfalse\t2026-10-08T07:00:00Z
  acme/never\tfalse\tfalse\t
  Gobinda168/Glance\tfalse\tfalse\t2026-10-09T00:00:00Z
  not a repository
  """
  let list = GitHubAccount.repositories(output)
  #expect(list.map(\.name) == ["acme/api", "gobinda168/glance", "acme/never"])
  #expect(list.map(\.isPrivate) == [true, true, false])
  #expect(list[0].pushedAt == (try Date("2026-10-08T07:00:00Z", strategy: .iso8601)))
  #expect(list[2].pushedAt == nil)
}

@Test func theRepositoryListAsksForEveryAffiliationNewestPushFirst() {
  let arguments = GitHubAccount.repositoriesArguments
  #expect(arguments.starts(with: ["api", "--paginate"]))
  #expect(arguments.contains("user/repos?affiliation=owner,collaborator,organization_member&sort=pushed&per_page=100"))
  #expect(arguments.last == ".[] | [.full_name, .private, .archived, .pushed_at] | @tsv")
}

@Test func theSavedListRoundTripsAndGoesStaleAfterTenMinutes() throws {
  let readAt = Date(timeIntervalSince1970: 1_000_000)
  let saved = GitHubAccount.Saved(login: "gobinda168", readAt: readAt,
                                  repositories: [.init(name: "o/r", isPrivate: true, pushedAt: readAt)])
  let data = try #require(saved.encoded())
  #expect(GitHubAccount.Saved.decode(data) == saved)
  #expect(!saved.isStale(at: readAt.addingTimeInterval(9 * 60)))
  #expect(saved.isStale(at: readAt.addingTimeInterval(10 * 60)))
  #expect(saved.belongs(to: "Gobinda168"))
  #expect(!saved.belongs(to: "someone"))
  #expect(GitHubAccount.Saved.decode(Data("not json".utf8)) == nil)
}

@Test func ghRunsWithPromptsUpdateNoticesAndColourOff() {
  let environment = GitHubCLI.environment(["GIT_INDEX_FILE": "/tmp/index"])
  #expect(environment["GH_PROMPT_DISABLED"] == "1")
  #expect(environment["GH_NO_UPDATE_NOTIFIER"] == "1")
  #expect(environment["NO_COLOR"] == "1")
  #expect(environment["GIT_INDEX_FILE"] == "/tmp/index")
}
