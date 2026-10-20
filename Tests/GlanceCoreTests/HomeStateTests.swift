import Foundation
import Testing
@testable import GlanceCore

private let home = "/Users/me"
private let now = Date(timeIntervalSince1970: 1_000_000)

private func project(_ name: String, branch: String? = nil, when: String = "1h ago") -> HomeState.Project {
  HomeState.Project(name: name, path: "/Users/me/\(name)", display: "~/\(name)", branch: branch, when: when)
}

private func state(recent: [HomeState.Project]) -> HomeState {
  HomeState(version: "1.4.0", greetingName: nil, showAtLaunch: true, editorName: "Razor Code",
            paneOpen: false, folder: nil, claude: .idle, usage: nil, recent: recent)
}

// MARK: State

@Test func theFolderNamesItsProjectBranchAndChanges() {
  let folder = HomeState.Folder(path: "/Users/me/Code/glance/", branch: "main", changes: 3, home: home)
  #expect(folder == HomeState.Folder(display: "~/Code/glance", name: "glance", branch: "main", changes: 3))
}

@Test func aFolderOutsideGitHasNoBranchOrChanges() {
  let folder = HomeState.Folder(path: "/opt/tools", branch: nil, changes: nil, home: home)
  #expect(folder == HomeState.Folder(display: "/opt/tools", name: "tools", branch: nil, changes: nil))
}

@Test func usageGivesEachWindowsPercentAndCountdown() {
  let plan = PlanUsage(fiveHour: PlanUsage.Window(percent: 12.4, resetsAt: now.addingTimeInterval(3 * 3600 + 7 * 60)),
                       sevenDay: nil)
  let usage = HomeState.Usage(plan, now: now)
  #expect(usage == HomeState.Usage(fiveHour: HomeState.Usage.Window(percent: 12, resets: "3h 7m"), sevenDay: nil))
}

@Test func aUsageWindowRunsHighFromSeventyAndNearTheLimitFromNinety() {
  #expect(HomeState.Usage.Window(percent: 69, resets: "1h").severity == .normal)
  #expect(HomeState.Usage.Window(percent: 70, resets: "1h").severity == .warn)
  #expect(HomeState.Usage.Window(percent: 89, resets: "1h").severity == .warn)
  #expect(HomeState.Usage.Window(percent: 90, resets: "1h").severity == .critical)
  #expect(PlanUsage.Window(percent: 69.6, resetsAt: now).severity == .warn) // the top bar rounds the same way
}

@Test func aRecentProjectHasItsNamesBranchAndAge() {
  let entry = RecentProjects.Entry(path: "/Users/me/Code/glance", lastActive: now.addingTimeInterval(-2 * 3600))
  let listed = HomeState.Project(entry, branch: nil, now: now, home: home)
  #expect(listed == HomeState.Project(name: "glance", path: "/Users/me/Code/glance", display: "~/Code/glance",
                                      branch: nil, when: "2h ago"))
}

@Test func theLogShowsAShortAge() {
  #expect(project("a", when: "2h ago").shortAge == "2h")
  #expect(project("a", when: "3d ago").shortAge == "3d")
  #expect(project("a", when: "just now").shortAge == "now")
  #expect(project("a", when: "yesterday").shortAge == "yesterday")
}

@Test func homeListsAtMostEightRecentProjects() {
  let projects = (0..<12).map { project("p\($0)", when: "just now") }
  let listed = state(recent: projects).recent
  #expect(listed.count == HomeState.recentLimit)
  #expect(HomeState.recentLimit == 8)
  #expect(listed.first?.name == "p0")
}

@Test func theGreetingUsesTheFirstName() {
  #expect(HomeState.greetingName(fullName: "Gobinda Das") == "Gobinda")
  #expect(HomeState.greetingName(fullName: "  ada  ") == "ada")
  #expect(HomeState.greetingName(fullName: "") == nil)
  #expect(HomeState.greetingName(fullName: "   ") == nil)
}

@Test func pathsUnderHomeAreShownWithATilde() {
  #expect(HomeState.display("/Users/me/Code/glance", home: home) == "~/Code/glance")
  #expect(HomeState.display("/Users/me", home: home) == "~")
  #expect(HomeState.display("/Users/meow/x", home: home) == "/Users/meow/x")
  #expect(HomeState.display("/opt/x/", home: home) == "/opt/x")
}

// MARK: News

@Test func theProjectYouWentBackToIsNewsNotTheOnesItPassed() {
  let before = [project("a"), project("b"), project("c")]
  #expect(HomeState.news(from: before, to: [project("c"), project("a"), project("b")]) == ["/Users/me/c"])
}

@Test func anArrivalAndABranchSwitchAreNews() {
  let before = [project("a"), project("b", branch: "main")]
  #expect(HomeState.news(from: before, to: [project("d"), project("a"), project("b", branch: "dev")])
    == ["/Users/me/d", "/Users/me/b"])
}

@Test func theSameListAndAGapClosingAreNoNews() {
  let before = [project("a"), project("b"), project("c")]
  #expect(HomeState.news(from: before, to: before).isEmpty)
  #expect(HomeState.news(from: before, to: [project("a"), project("c")]).isEmpty)
  #expect(HomeState.news(from: before, to: [project("a", when: "5m ago"), project("b"), project("c")]).isEmpty)
}
