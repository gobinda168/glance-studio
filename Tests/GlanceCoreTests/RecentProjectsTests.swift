import Foundation
import Testing
@testable import GlanceCore

private let home = "/Users/me"
private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func paths(_ list: RecentProjects) -> [String] { list.entries.map(\.path) }

@Test func aRecordedProjectGoesToTheFront() {
  var list = RecentProjects()
  list.record("/Users/me/Code/a", at: t0, home: home)
  list.record("/Users/me/Code/b", at: t0.addingTimeInterval(1), home: home)
  #expect(paths(list) == ["/Users/me/Code/b", "/Users/me/Code/a"])
  list.record("/Users/me/Code/a", at: t0.addingTimeInterval(2), home: home)
  #expect(paths(list) == ["/Users/me/Code/a", "/Users/me/Code/b"])
  #expect(list.entries.first?.lastActive == t0.addingTimeInterval(2))
}

@Test func aProjectIsListedOnceWhateverTheSpelling() {
  var list = RecentProjects()
  list.record("/Users/me/Code/a", at: t0, home: home)
  list.record("~/Code/a/", at: t0.addingTimeInterval(1), home: home)
  list.record("/Users/me/Code/./a", at: t0.addingTimeInterval(2), home: home)
  #expect(paths(list) == ["/Users/me/Code/a"])
  list.record("/private/tmp/x", at: t0.addingTimeInterval(3), home: home)
  list.record("/tmp/x", at: t0.addingTimeInterval(4), home: home)
  #expect(paths(list) == ["/tmp/x", "/Users/me/Code/a"])
}

@Test func homeAndRootAreNotProjects() {
  var list = RecentProjects()
  list.record("/Users/me", at: t0, home: home)
  list.record("~", at: t0, home: home)
  list.record("/Users/me/", at: t0, home: home)
  list.record("/", at: t0, home: home)
  list.record("", at: t0, home: home)
  #expect(list.entries.isEmpty)
}

@Test func theListKeepsTheTwelveNewest() {
  var list = RecentProjects()
  for index in 0..<15 {
    list.record("/Users/me/p\(index)", at: t0.addingTimeInterval(Double(index)), home: home)
  }
  #expect(list.entries.count == RecentProjects.capacity)
  #expect(RecentProjects.capacity == 12)
  #expect(list.entries.first?.path == "/Users/me/p14")
  #expect(list.entries.last?.path == "/Users/me/p3")
}

@Test func pruningDropsFoldersThatAreGone() {
  var list = RecentProjects()
  list.record("/Users/me/gone", at: t0, home: home)
  list.record("/Users/me/kept", at: t0.addingTimeInterval(1), home: home)
  list.record("/Users/me/also-gone", at: t0.addingTimeInterval(2), home: home)
  list.prune { $0 == "/Users/me/kept" }
  #expect(paths(list) == ["/Users/me/kept"])
}

@Test func theListSurvivesStorage() {
  var list = RecentProjects()
  list.record("/Users/me/a", at: t0, home: home)
  list.record("/Users/me/b c/ü", at: t0.addingTimeInterval(90), home: home)
  #expect(RecentProjects(data: list.encoded()) == list)
}

@Test func unreadableStorageIsAnEmptyList() {
  #expect(RecentProjects(data: nil).entries.isEmpty)
  #expect(RecentProjects(data: Data("not json".utf8)).entries.isEmpty)
  #expect(RecentProjects(data: Data(#"{"path":"/x"}"#.utf8)).entries.isEmpty)
}

@Test func storedListsLongerThanTheCapacityAreCut() {
  let entries = (0..<20).map { RecentProjects.Entry(path: "/p\($0)", lastActive: t0) }
  #expect(RecentProjects(entries: entries).entries.count == RecentProjects.capacity)
}

@Test func aSeededListIsNewestFirstAndSkipsUndatedProjects() {
  let dates: [String: Date] = [
    "/Users/me/old": t0,
    "/Users/me/new": t0.addingTimeInterval(500),
    "/Users/me/mid": t0.addingTimeInterval(100),
  ]
  let list = RecentProjects.seeded(
    paths: ["/Users/me/old", "/Users/me/undated", "/Users/me/new", "/Users/me/mid", "/Users/me"],
    lastActive: { dates[$0] ?? ($0 == "/Users/me" ? t0 : nil) }, home: home)
  #expect(paths(list) == ["/Users/me/new", "/Users/me/mid", "/Users/me/old"])
  #expect(list.entries.first?.lastActive == t0.addingTimeInterval(500))
}

@Test func agesReadLikeAClock() {
  let now = t0
  #expect(RecentProjects.age(of: now, now: now) == "just now")
  #expect(RecentProjects.age(of: now.addingTimeInterval(-59), now: now) == "just now")
  #expect(RecentProjects.age(of: now.addingTimeInterval(-60), now: now) == "1m ago")
  #expect(RecentProjects.age(of: now.addingTimeInterval(-5 * 60), now: now) == "5m ago")
  #expect(RecentProjects.age(of: now.addingTimeInterval(-3599), now: now) == "59m ago")
  #expect(RecentProjects.age(of: now.addingTimeInterval(-2 * 3600 - 1800), now: now) == "2h ago")
  #expect(RecentProjects.age(of: now.addingTimeInterval(-3 * 86400), now: now) == "3d ago")
  #expect(RecentProjects.age(of: now.addingTimeInterval(-6 * 86400 - 3600), now: now) == "6d ago")
  #expect(RecentProjects.age(of: now.addingTimeInterval(-14 * 86400), now: now) == "2w ago")
  #expect(RecentProjects.age(of: now.addingTimeInterval(-60 * 86400), now: now) == "8w ago")
}

@Test func aDateInTheFutureIsJustNow() {
  #expect(RecentProjects.age(of: t0.addingTimeInterval(3600), now: t0) == "just now")
}
