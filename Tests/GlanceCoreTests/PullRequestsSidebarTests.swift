import Foundation
import Testing
@testable import GlanceCore

private let failing = PullRequests.PullRequest(number: 51, title: "Release", checks: .init(passed: 13, failed: 1))
private let passing = PullRequests.PullRequest(number: 50, title: "Sparkle", author: "mira-k", checks: .init(passed: 14))
private let draft = PullRequests.PullRequest(number: 49, title: "Version stamping", isDraft: true,
                                             checks: .init(failed: 1))
private let merged = PullRequests.PullRequest(number: 47, title: "Changes view",
                                              mergedAt: Date(timeIntervalSince1970: 1_000))

@Test func everythingShowsByDefault() {
  let filter = PullRequests.Filter()
  #expect(PullRequests.visible([failing, passing, draft], in: .yours, filter: filter) == [failing, passing, draft])
  #expect(PullRequests.visible([merged], in: .recentlyMerged, filter: filter) == [merged])
  #expect(!filter.isNarrowed)
}

@Test func draftsHideWithoutShowDrafts() {
  let filter = PullRequests.Filter(showsDrafts: false)
  #expect(PullRequests.visible([failing, draft], in: .yours, filter: filter) == [failing])
  #expect(PullRequests.visible([draft], in: .waitingOnYou, filter: filter).isEmpty)
  #expect(filter.isNarrowed)
}

@Test func failingChecksOnlyKeepsOpenPullRequestsWhoseChecksFail() {
  let filter = PullRequests.Filter(failingOnly: true)
  #expect(PullRequests.visible([failing, passing, draft], in: .yours, filter: filter) == [failing, draft])
  #expect(PullRequests.visible([merged], in: .recentlyMerged, filter: filter).isEmpty)
  #expect(filter.isNarrowed)
}

@Test func theTextStillFiltersUnderTheMenu() {
  #expect(PullRequests.visible([failing, passing], in: .yours, filter: .init(text: "mira")) == [passing])
  #expect(PullRequests.visible([failing, passing], in: .yours, filter: .init(text: "#51")) == [failing])
}

@Test func theThreeTabsAlwaysShowWithWhatTheFilterLeavesEach() {
  let board = PullRequests.Board(repository: "o/r", waitingOnYou: [], yours: [failing, passing, draft],
                                 recentlyMerged: [merged])
  #expect(PullRequests.tabs(board, filter: .init())
    == [.init(list: .waitingOnYou, count: 0), .init(list: .yours, count: 3), .init(list: .recentlyMerged, count: 1)])
  #expect(PullRequests.tabs(board, filter: .init(text: "mira")).map(\.count) == [0, 1, 0])
  #expect(PullRequests.tabs(board, filter: .init(failingOnly: true)).map(\.count) == [0, 2, 0])
  #expect(PullRequests.List.allCases.map(\.title) == ["To review", "Yours", "Merged"])
}

@Test func anEmptyTabSaysWhy() {
  #expect(PullRequests.emptyText(.waitingOnYou, filter: .init()) == "Nothing is waiting on your review.")
  #expect(PullRequests.emptyText(.yours, filter: .init()) == "You have no open pull requests.")
  #expect(PullRequests.emptyText(.recentlyMerged, filter: .init()) == "Nothing of yours merged recently.")
  #expect(PullRequests.emptyText(.yours, filter: .init(text: " zzz ")) == "Nothing matches “zzz”.")
  #expect(PullRequests.emptyText(.yours, filter: .init(showsDrafts: false)) == "Nothing matches the filter.")
}

@Test func theTabFollowsThePullRequestInFront() {
  let review = PullRequests.PullRequest(number: 7, title: "Cache", repository: "Owner/Repo")
  let mine = PullRequests.PullRequest(number: 8, title: "Mine", repository: "owner/repo")
  let board = PullRequests.Board(repository: "owner/repo", waitingOnYou: [review], yours: [mine], recentlyMerged: [])
  // The tab that lists it, whatever the case of its repository.
  #expect(PullRequests.tab(.recentlyMerged, showing: 7, of: "owner/repo", in: board) == .waitingOnYou)
  #expect(PullRequests.tab(.waitingOnYou, showing: 8, of: "OWNER/REPO", in: board) == .yours)
  // The tab shown holds while it lists it, or while no tab does.
  #expect(PullRequests.tab(.yours, showing: 8, of: "owner/repo", in: board) == .yours)
  #expect(PullRequests.tab(.yours, showing: 99, of: "owner/repo", in: board) == .yours)
  #expect(PullRequests.tab(.yours, showing: 7, of: "other/repo", in: board) == .yours)
}

@Test func theTabIsSavedByName() {
  #expect(PullRequests.List(rawValue: PullRequests.List.yours.rawValue) == .yours)
  #expect(PullRequests.List(rawValue: "groups") == nil)
}
