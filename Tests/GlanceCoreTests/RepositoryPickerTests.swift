import Foundation
import Testing
@testable import GlanceCore

private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: Double(n) * 86_400) }
private let glance = GitHubAccount.Repository(name: "gobinda168/glance", isPrivate: true, pushedAt: day(9))
private let site = GitHubAccount.Repository(name: "gobinda168/glance-site", pushedAt: day(8))
private let api = GitHubAccount.Repository(name: "acme/api", isPrivate: true, pushedAt: day(7))
private let ghost = GitHubAccount.Repository(name: "acme/ghostly", pushedAt: day(10))
private let all = [ghost, glance, site, api]

@Test func withoutAFilterThePickerShowsThisTabRecentThenAll() {
  let groups = RepositoryPicker.groups(all: all, recent: ["acme/api", "gone/away"], thisTab: "Gobinda168/Glance",
                                       filter: "")
  #expect(groups.map(\.section) == [.thisTab, .recent, .all])
  #expect(groups[0].repositories == [glance]) // looked up in the account's list, whatever the case
  #expect(groups[1].repositories == [api, GitHubAccount.Repository(name: "gone/away")])
  #expect(groups[2].repositories == all)
}

@Test func emptySectionsAreLeftOut() {
  #expect(RepositoryPicker.groups(all: [], recent: [], thisTab: nil, filter: "").isEmpty)
  #expect(RepositoryPicker.groups(all: all, recent: [], thisTab: nil, filter: "").map(\.section) == [.all])
}

@Test func filteringMergesTheSectionsIntoOneList() {
  let groups = RepositoryPicker.groups(all: all, recent: ["acme/api"], thisTab: "gobinda168/glance", filter: " GLA ")
  #expect(groups.map(\.section) == [.matches])
  #expect(groups[0].repositories == [glance, site]) // each once, newest push first
}

@Test func theOwnerOrTheWholeNameCountsAsAStart() {
  #expect(RepositoryPicker.groups(all: all, recent: [], thisTab: nil, filter: "acme/")[0].repositories == [ghost, api])
  #expect(RepositoryPicker.groups(all: all, recent: [], thisTab: nil, filter: "host")[0].repositories == [ghost])
}

@Test func namesStartingWithTheTextComeBeforeOtherMatches() {
  let repositories = [GitHubAccount.Repository(name: "x/my-api", pushedAt: day(20)), api]
  let groups = RepositoryPicker.groups(all: repositories, recent: [], thisTab: nil, filter: "api")
  #expect(groups[0].repositories.map(\.name) == ["acme/api", "x/my-api"])
}

@Test func noMatchesMeansNoGroups() {
  #expect(RepositoryPicker.groups(all: all, recent: [], thisTab: nil, filter: "zzz").isEmpty)
  #expect(RepositoryPicker.matches(api, filter: "ACME"))
  #expect(!RepositoryPicker.matches(api, filter: "zzz"))
}

@Test func aPickGoesFirstInRecentOnceAndRecentKeepsFive() {
  #expect(RepositoryPicker.recent(after: "a/b", in: []) == ["a/b"])
  #expect(RepositoryPicker.recent(after: "A/B", in: ["x/y", "a/b"]) == ["A/B", "x/y"])
  #expect(RepositoryPicker.recent(after: "f/f", in: ["a/a", "b/b", "c/c", "d/d", "e/e"])
    == ["f/f", "a/a", "b/b", "c/c", "d/d"])
}
