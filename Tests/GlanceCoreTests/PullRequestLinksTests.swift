import Foundation
import Testing
@testable import GlanceCore

@Test func referencesBecomeLinksGlanceOpens() {
  #expect(PullRequestLinks.autolink("Fixes #12 and #3.") == "Fixes [#12](glance-ref:12) and [#3](glance-ref:3).")
  #expect(PullRequestLinks.autolink("#12 first") == "[#12](glance-ref:12) first")
  #expect(PullRequestLinks.autolink("(#7) and (see #8)") == "([#7](glance-ref:7)) and (see [#8](glance-ref:8))")
  #expect(PullRequestLinks.autolink("- [ ] #4, then #5") == "- [ ] [#4](glance-ref:4), then [#5](glance-ref:5)")
}

@Test func codeAndExistingLinksKeepTheirNumbers() {
  #expect(PullRequestLinks.autolink("use `#12` here, not #13") == "use `#12` here, not [#13](glance-ref:13)")
  #expect(PullRequestLinks.autolink("```\ngit log #12\n```\nafter #2") == "```\ngit log #12\n```\nafter [#2](glance-ref:2)")
  #expect(PullRequestLinks.autolink("[#12](https://example.com)") == "[#12](https://example.com)")
  #expect(PullRequestLinks.autolink("abc#12 and #12a") == "abc#12 and #12a")
}

@Test func thisRepositorysPullRequestsAndIssuesOpenInGlance() throws {
  let repository = "gobinda168/glance"
  #expect(PullRequestLinks.target(try #require(URL(string: "glance-ref:12")), repository: repository) == .number(12))
  #expect(PullRequestLinks.target(try #require(URL(string: "https://github.com/gobinda168/glance/pull/51")),
                                  repository: repository) == .number(51))
  #expect(PullRequestLinks.target(try #require(URL(string: "https://github.com/Gobinda168/Glance/issues/12#issuecomment-9")),
                                  repository: repository) == .number(12))
  let other = try #require(URL(string: "https://github.com/cli/cli/pull/1"))
  #expect(PullRequestLinks.target(other, repository: repository) == .external(other))
  let site = try #require(URL(string: "https://sparkle-project.org/documentation/"))
  #expect(PullRequestLinks.target(site, repository: repository) == .external(site))
}
