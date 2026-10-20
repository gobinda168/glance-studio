import Testing
@testable import GlanceCore

@Test func ownerSlashRepoClonesWithGh() {
  #expect(CloneSource.plan("acme/invoice-service", parent: "/Users/me/Code")
    == .init(tool: .gh, arguments: ["repo", "clone", "acme/invoice-service", "/Users/me/Code/invoice-service"],
             destination: "/Users/me/Code/invoice-service"))
}

@Test func gitHubURLsCloneWithGhAsOwnerSlashRepo() {
  let expected = CloneSource.Plan(tool: .gh, arguments: ["repo", "clone", "acme/api", "/c/api"], destination: "/c/api")
  #expect(CloneSource.plan("https://github.com/acme/api", parent: "/c") == expected)
  #expect(CloneSource.plan("https://github.com/acme/api.git", parent: "/c") == expected)
  #expect(CloneSource.plan("  github.com/acme/api/  ", parent: "/c") == expected)
  #expect(CloneSource.plan("git@github.com:acme/api.git", parent: "/c") == expected)
}

@Test func otherGitURLsCloneWithGit() {
  #expect(CloneSource.plan("https://gitlab.com/team/tools.git", parent: "/c")
    == .init(tool: .git, arguments: ["clone", "https://gitlab.com/team/tools.git", "/c/tools"], destination: "/c/tools"))
  #expect(CloneSource.plan("git@bitbucket.org:team/site.git", parent: "/c")
    == .init(tool: .git, arguments: ["clone", "git@bitbucket.org:team/site.git", "/c/site"], destination: "/c/site"))
}

@Test func textThatIsntARepositoryHasNoPlan() {
  #expect(CloneSource.plan("", parent: "/c") == nil)
  #expect(CloneSource.plan("invoice service", parent: "/c") == nil)
  #expect(CloneSource.plan("just-a-name", parent: "/c") == nil)
  #expect(CloneSource.plan("https://github.com/acme", parent: "/c") == nil)
}

@Test func theFolderNameIsTheRepositorysName() {
  #expect(CloneSource.name(of: "acme/api") == "api")
  #expect(CloneSource.name(of: "https://gitlab.com/team/tools.git") == "tools")
  #expect(CloneSource.name(of: "nope") == nil)
}
