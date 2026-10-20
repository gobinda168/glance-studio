import Foundation
import Testing
@testable import GlanceCore

@Test func theQueueKeepsTenAndDropsTheOldest() {
  var queue = AutomationRunQueue<Int>()
  for item in 1...10 { #expect(queue.push(item) == nil) }
  #expect(queue.push(11) == 1)
  #expect(queue.count == 10)
  #expect(queue.pop() == 2)
  queue.removeAll()
  #expect(queue.pop() == nil)
}

@Test func aCrashingWatcherWaitsLongerThenBreaks() {
  var backoff = WatcherBackoff()
  let start = Date(timeIntervalSince1970: 0)
  #expect(backoff.crashed(at: start) == .restart(after: 5))
  #expect(backoff.crashed(at: start.addingTimeInterval(10)) == .restart(after: 10))
  #expect(backoff.crashed(at: start.addingTimeInterval(30)) == .restart(after: 20))
  #expect(backoff.crashed(at: start.addingTimeInterval(60)) == .restart(after: 40))
  #expect(backoff.crashed(at: start.addingTimeInterval(120)) == .broken)
}

@Test func crashesSpreadOutNeverBreakAndTheWaitTopsOutAtFiveMinutes() {
  var backoff = WatcherBackoff()
  var outcomes: [WatcherBackoff.Outcome] = []
  for minute in stride(from: 0, to: 80, by: 4) {
    outcomes.append(backoff.crashed(at: Date(timeIntervalSince1970: Double(minute) * 60)))
  }
  #expect(!outcomes.contains(.broken))
  #expect(outcomes.last == .restart(after: 300))
  backoff.succeeded()
  #expect(backoff.crashed(at: Date(timeIntervalSince1970: 90 * 60)) == .restart(after: 5))
}

@Test func aNewScheduleIsArmedAtNowAndNeverCatchesUp() throws {
  let calendar = Calendar(identifier: .gregorian)
  let daily = try CronSchedule(parsing: "0 9 * * *")
  let key = AutomationScheduleState.key(automation: "digest", index: 1, cron: "0 9 * * *")
  #expect(key == "digest triggers[1] 0 9 * * *")
  var state = AutomationScheduleState()
  let tenAM = Date(timeIntervalSince1970: 1_791_540_000)  // 2026-10-09 10:00 UTC
  var utc = calendar
  utc.timeZone = TimeZone(identifier: "UTC")!
  #expect(state.arm([key: daily], now: tenAM, calendar: utc).isEmpty)
  #expect(state.lastFires[key] == tenAM)
  // Studio was closed over the next morning's 9:00: the launch after catches up once.
  let nextNoon = tenAM.addingTimeInterval(26 * 3600)
  #expect(state.arm([key: daily], now: nextNoon, calendar: utc) == [key])
  state.fired(key, at: nextNoon)
  #expect(state.arm([key: daily], now: nextNoon.addingTimeInterval(60), calendar: utc).isEmpty)
  // Disarmed schedules are forgotten.
  #expect(state.arm([:], now: nextNoon, calendar: utc).isEmpty)
  #expect(state.lastFires.isEmpty)
}

@Test func theNextFireIsTheSoonestAcrossSchedules() throws {
  var utc = Calendar(identifier: .gregorian)
  utc.timeZone = TimeZone(identifier: "UTC")!
  let now = Date(timeIntervalSince1970: 1_791_536_430)  // 09:00:30 UTC
  let schedules = ["a": try CronSchedule(parsing: "* * * * *"), "b": try CronSchedule(parsing: "1 9 * * *"),
                   "c": try CronSchedule(parsing: "0 10 * * *")]
  let next = AutomationScheduleState.next(schedules, after: now, calendar: utc)
  #expect(next?.date == Date(timeIntervalSince1970: 1_791_536_460))
  #expect(next?.keys == ["a", "b"])
  #expect(AutomationScheduleState.next([:], after: now, calendar: utc) == nil)
}

@Test func scheduleStateRoundTripsAndABadFileIsNil() {
  let state = AutomationScheduleState(lastFires: ["a triggers[0] * * * * *": Date(timeIntervalSince1970: 1_791_536_400)])
  #expect(String(decoding: state.encoded(), as: UTF8.self).contains("\"2026-10-09T09:00:00.000Z\""))
  #expect(AutomationScheduleState.decode(state.encoded()) == state)
  #expect(AutomationScheduleState.decode(Data(#"{"a": "yesterday"}"#.utf8)) == nil)
  #expect(AutomationScheduleState.decode(Data("[]".utf8)) == nil)
}

@Test func eventFiltersAreEqualityOnPayloadFields() {
  let payload = AutomationValue.object(["repo": .string("acme/app"), "number": .number(412)])
  #expect(AutomationTriggerMatch.matches(nil, payload))
  #expect(AutomationTriggerMatch.matches(["repo": .string("acme/app")], payload))
  #expect(AutomationTriggerMatch.matches(["number": .string("412")], payload))
  #expect(!AutomationTriggerMatch.matches(["repo": .string("acme/web")], payload))
  #expect(!AutomationTriggerMatch.matches(["sha": .string("x")], payload))
}

@Test func globsMatchNamesCaseInsensitively() {
  #expect(AutomationTriggerMatch.glob("*.pdf", matches: "Invoice.PDF"))
  #expect(!AutomationTriggerMatch.glob("*.pdf", matches: "a/b.pdf"))
  #expect(AutomationTriggerMatch.glob("**/*.pdf", matches: "a/b.pdf"))
  #expect(AutomationTriggerMatch.glob("**/*.pdf", matches: "b.pdf"))
  #expect(AutomationTriggerMatch.glob("**/*.pdf", matches: "a/b/c.pdf"))
  #expect(!AutomationTriggerMatch.glob("**/*.pdf", matches: "b.txt"))
  #expect(AutomationTriggerMatch.glob("report-??.csv", matches: "report-01.csv"))
  #expect(AutomationTriggerMatch.glob("[ab]*.txt", matches: "b1.txt"))
  #expect(!AutomationTriggerMatch.glob("[ab]*.txt", matches: "c1.txt"))
  #expect(AutomationTriggerMatch.glob("*", matches: ""))
}

// Review Focus: Finder's .DS_Store and editors' swap files never fire a "*" files trigger.
@Test func changedPathsUnderTheFolderMatchingTheGlob() {
  let paths = ["/Users/me/Downloads/a.pdf", "/Users/me/Downloads/b.txt", "/Users/me/Downloads/.DS_Store",
               "/Users/me/Downloads/sub/c.pdf", "/Users/me/Downloadsx/d.pdf", "/Users/me/Downloads/a.pdf"]
  #expect(AutomationTriggerMatch.changedPaths(paths, root: "/Users/me/Downloads/", glob: "*.pdf")
    == ["/Users/me/Downloads/a.pdf", "/Users/me/Downloads/sub/c.pdf"])
  #expect(AutomationTriggerMatch.changedPaths(paths, root: "/Users/me/Downloads", glob: nil)
    == ["/Users/me/Downloads/a.pdf", "/Users/me/Downloads/b.txt", "/Users/me/Downloads/sub/c.pdf"])
  #expect(AutomationTriggerMatch.changedPaths(paths, root: "/Users/me/Downloads", glob: "sub/*.pdf")
    == ["/Users/me/Downloads/sub/c.pdf"])
  #expect(AutomationTriggerMatch.changedPaths(["/Users/me/notes.md"], root: "/Users/me/notes.md", glob: nil)
    == ["/Users/me/notes.md"])
  #expect(AutomationTriggerMatch.expand("~/Downloads", home: "/Users/me") == "/Users/me/Downloads")
  #expect(AutomationTriggerMatch.filesPayload(["/a"]).json == #"{"paths":["/a"]}"#)
  #expect(AutomationTriggerMatch.schedulePayload(cron: "0 9 * * *", at: Date(timeIntervalSince1970: 1_791_536_400)).json
    == #"{"at":"2026-10-09T09:00:00.000Z","cron":"0 9 * * *"}"#)
}

// Review fix: a change deep inside a hidden folder (.git/objects, .cache) never fires a "*" or no-glob trigger.
@Test func hiddenFoldersAreSkippedUnlessTheGlobAsksForThem() {
  let root = "/Users/me/repo"
  let paths = ["\(root)/sub/.git/x", "\(root)/.git/objects/ab/cdef", "\(root)/.cache/x.tmp",
               "\(root)/.github/ci.yml", "\(root)/src/a.swift"]
  #expect(AutomationTriggerMatch.changedPaths(paths, root: root, glob: nil) == ["\(root)/src/a.swift"])
  #expect(AutomationTriggerMatch.changedPaths(paths, root: root, glob: "*") == ["\(root)/src/a.swift"])
  #expect(AutomationTriggerMatch.changedPaths(paths, root: root, glob: ".github/*.yml") == ["\(root)/.github/ci.yml"])
  #expect(AutomationTriggerMatch.changedPaths(paths, root: root, glob: "**/.git/*") == ["\(root)/sub/.git/x"])
}
