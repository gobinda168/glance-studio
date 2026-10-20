import Foundation
import Testing
@testable import GlanceCore

private let utc = JournalDay.calendar(timeZone: TimeZone(identifier: "UTC")!)
private let october9 = JournalDay(key: "2026-10-09")!.interval(in: utc)

private let output = """
  \u{1e}abc123\u{1f}2026-10-09T10:15:00+00:00\u{1f}fix: the tab bar

   3 files changed, 40 insertions(+), 2 deletions(-)
  \u{1e}def456\u{1f}2026-10-09T12:00:00Z\u{1f}chore: empty commit
  \u{1e}old999\u{1f}2026-10-08T23:00:00Z\u{1f}yesterday

   1 file changed, 1 insertion(+)

  """

@Test func aLogBecomesOneEventPerCommitInTheRange() {
  let events = JournalGit.parse(output, root: "/r", range: october9, calendar: utc)
  #expect(events.map(\.externalID) == ["abc123", "def456"])
  #expect(events[0].title == "fix: the tab bar")
  #expect(events[0].project == "/r")
  #expect(events[0].source == .git)
  #expect(events[0].detail.filesChanged == 3)
  #expect(events[0].detail.insertions == 40)
  #expect(events[0].detail.deletions == 2)
  #expect(events[1].detail.insertions == nil)
  #expect(events[1].day.key == "2026-10-09")
}

@Test func aCommitSubjectIsRedacted() {
  let log = "\u{1e}aaa\u{1f}2026-10-09T10:00:00Z\u{1f}set API_TOKEN=abc123 for staging\n"
  let title = JournalGit.parse(log, root: "/r", range: october9, calendar: utc).first?.title ?? ""
  #expect(title.contains("‹redacted›"))
  #expect(!title.contains("abc123"))
}

@Test func theLogAsksForTheAuthorsCommitsInTheRange() {
  let arguments = JournalGit.logArguments(root: "/r", email: "me+x@example.com", range: october9, calendar: utc)
  #expect(arguments.prefix(5) == ["-C", "/r", "log", "--all", "--no-merges"])
  #expect(arguments.contains("--fixed-strings"))
  #expect(arguments.contains("--author=<me+x@example.com>"))
  #expect(arguments.contains("--since=2026-10-09T00:00:00Z"))
  #expect(arguments.contains("--until=2026-10-10T00:00:00Z"))
  #expect(arguments.contains("--shortstat"))
  #expect(JournalGit.rootArguments(folder: "/r/src") == ["-C", "/r/src", "rev-parse", "--show-toplevel"])
  #expect(JournalGit.emailArguments(root: "/r") == ["-C", "/r", "config", "user.email"])
}

@Test func rootsAreResolvedOnceAndNeverTheHomeFolderOrRoot() {
  let resolved: [String: String] = [
    "/Users/me/Code/app": "/Users/me/Code/app", "/Users/me/Code/app/src": "/Users/me/Code/app",
    "/Users/me/Code/site": "/Users/me/Code/site", "/Users/me/dotfiles": "/Users/me",
  ]
  let roots = JournalGit.roots(
    ["/Users/me/Code/app", "~/Code/app/src", "/Users/me/Code/site/", "/", "/Users/me", "/Users/me/dotfiles",
     "/Users/me/gone"],
    home: "/Users/me", resolve: { resolved[$0] })
  #expect(roots == ["/Users/me/Code/app", "/Users/me/Code/site"])
}
