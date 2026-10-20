import Foundation
import Testing
@testable import GlanceCore

private let now = Date(timeIntervalSince1970: 1_700_000_000)

/// A status-line payload with the given windows: (used %, seconds from `now` until reset).
private func payload(five: (Double, Double)? = nil, seven: (Double, Double)? = nil, extra: String = "") -> Data {
  var windows: [String] = []
  if let five { windows.append("\"five_hour\":{\"used_percentage\":\(five.0),\"resets_at\":\(1_700_000_000 + five.1)}") }
  if let seven { windows.append("\"seven_day\":{\"used_percentage\":\(seven.0),\"resets_at\":\(1_700_000_000 + seven.1)}") }
  let limits = windows.isEmpty ? "" : "\"rate_limits\":{\(windows.joined(separator: ","))}"
  let parts = [extra, limits].filter { !$0.isEmpty }
  return Data("{\(parts.joined(separator: ","))}".utf8)
}

@Test func bothWindowsParse() throws {
  let usage = try #require(PlanUsage.parse(payload(five: (23.5, 7800), seven: (41.2, 273_600), extra: "\"model\":{\"id\":\"x\"}"), now: now))
  #expect(usage.fiveHour?.percent == 23.5)
  #expect(usage.fiveHour?.resetsAt == now.addingTimeInterval(7800))
  #expect(usage.sevenDay?.percent == 41.2)
}

@Test func oneWindowIsEnough() throws {
  let usage = try #require(PlanUsage.parse(payload(seven: (10, 3600)), now: now))
  #expect(usage.fiveHour == nil)
  #expect(usage.sevenDay?.shownPercent == 10)
}

@Test func nothingToShowIsNil() {
  #expect(PlanUsage.parse(payload(extra: "\"model\":{}"), now: now) == nil) // no rate_limits (API-key user)
  #expect(PlanUsage.parse(Data(), now: now) == nil)
  #expect(PlanUsage.parse(Data("not json".utf8), now: now) == nil)
  #expect(PlanUsage.parse(Data("{\"rate_limits\":".utf8), now: now) == nil) // half-written
  #expect(PlanUsage.parse(Data("[1,2]".utf8), now: now) == nil)
  #expect(PlanUsage.parse(Data("{\"rate_limits\":{\"five_hour\":{\"resets_at\":1700009999}}}".utf8), now: now) == nil) // no percentage
}

@Test func expiredWindowsAreDropped() throws {
  let usage = try #require(PlanUsage.parse(payload(five: (90, -1), seven: (41, 100)), now: now))
  #expect(usage.fiveHour == nil)
  #expect(usage.sevenDay != nil)
  #expect(PlanUsage.parse(payload(five: (90, 0), seven: (41, -5000)), now: now) == nil) // a reset at exactly `now` is over
}

@Test func percentagesAreClampedAndRounded() throws {
  let usage = try #require(PlanUsage.parse(payload(five: (-5, 60), seven: (140, 60)), now: now))
  #expect(usage.fiveHour?.percent == 0)
  #expect(usage.sevenDay?.percent == 100)
  let rounded = try #require(PlanUsage.parse(payload(five: (23.5, 60), seven: (23.4, 60)), now: now))
  #expect(rounded.fiveHour?.shownPercent == 24)
  #expect(rounded.sevenDay?.shownPercent == 23)
}

@Test func severityFollowsTheShownNumber() throws {
  func severity(_ percent: Double) throws -> PlanUsage.Window.Severity {
    try #require(PlanUsage.parse(payload(five: (percent, 60)), now: now)?.fiveHour?.severity)
  }
  #expect(try severity(69.4) == .normal)
  #expect(try severity(69.6) == .warn) // shown as 70%
  #expect(try severity(89.4) == .warn)
  #expect(try severity(89.5) == .critical) // shown as 90%
  #expect(try severity(100) == .critical)
}

@Test func resetTextAtTheBoundaries() throws {
  func text(_ seconds: Double) throws -> String {
    try #require(PlanUsage.parse(payload(five: (1, seconds)), now: now)?.fiveHour?.resetText(now: now))
  }
  #expect(try text(45) == "resets in under a minute")
  #expect(try text(25 * 60) == "resets in 25m")
  #expect(try text(7200) == "resets in 2h")
  #expect(try text(7800) == "resets in 2h 10m")
  #expect(try text(3 * 86400 + 4 * 3600) == "resets in 3d 4h")
  #expect(try text(2 * 86400) == "resets in 2d")
}

@Test func ageText() {
  #expect(PlanUsage.ageText(updated: now.addingTimeInterval(-20), now: now) == "updated just now")
  #expect(PlanUsage.ageText(updated: now.addingTimeInterval(-240), now: now) == "updated 4m ago")
  #expect(PlanUsage.ageText(updated: now.addingTimeInterval(-3 * 3600), now: now) == "updated 3h ago")
  #expect(PlanUsage.ageText(updated: now.addingTimeInterval(-2 * 86400), now: now) == "updated 2d ago")
  #expect(PlanUsage.ageText(updated: now.addingTimeInterval(30), now: now) == "updated just now") // clock skew
}

@Test func loadReadsTheFileAndItsModificationTime() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("plan-usage-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  let file = dir.appendingPathComponent("usage.json")
  #expect(PlanUsage.load(from: file, now: now) == nil) // missing

  try payload(five: (23, 7800)).write(to: file)
  let modified = now.addingTimeInterval(-600)
  try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
  let loaded = try #require(PlanUsage.load(from: file, now: now))
  #expect(loaded.usage.fiveHour?.shownPercent == 23)
  #expect(abs(loaded.updated.timeIntervalSince(modified)) < 1)

  // The same file, a few hours later: the window has reset, so there's nothing to show.
  #expect(PlanUsage.load(from: file, now: now.addingTimeInterval(3 * 3600)) == nil)

  try Data().write(to: file) // emptied
  #expect(PlanUsage.load(from: file, now: now) == nil)
}

@Test func aResetImplausiblyFarAheadIsIgnored() {
  #expect(PlanUsage.parse(payload(five: (50, 1e20)), now: now) == nil) // converting this to Int would trap
  #expect(PlanUsage.parse(payload(five: (50, 9 * 86400)), now: now) == nil)
  #expect(PlanUsage.parse(payload(seven: (50, 7 * 86400)), now: now) != nil)
}

@Test func theShortResetText() throws {
  func short(_ seconds: Double) throws -> String {
    try #require(PlanUsage.parse(payload(five: (1, seconds)), now: now)?.fiveHour?.shortResetText(now: now))
  }
  #expect(try short(45) == "<1m")
  #expect(try short(25 * 60) == "25m")
  #expect(try short(7800) == "2h 10m")
  #expect(try short(3 * 86400 + 4 * 3600) == "3d 4h")
  let five = try #require(PlanUsage.parse(payload(five: (23.5, 7800)), now: now)?.fiveHour)
  #expect(five.resetText(now: now) == "resets in 2h 10m")
}

// MARK: UsageTracker: several Claude sessions write usage.json, an idle one with an older snapshot too

private typealias Reading = (usage: PlanUsage, updated: Date)

private func reading(_ five: (Double, Double)? = nil, seven: (Double, Double)? = nil, updated: Double = 0) -> Reading {
  (PlanUsage.parse(payload(five: five, seven: seven), now: now)!, now.addingTimeInterval(updated))
}

@Test func aStaleLowerSnapshotDoesNotRollTheNumbersBack() {
  var tracker = UsageTracker()
  _ = tracker.update(reading((40, 7200), seven: (60, 300_000), updated: -100), now: now)
  let out = tracker.update(reading((30, 7200), seven: (55, 300_000), updated: 0), now: now) // an idle session's older snapshot
  #expect(out?.usage.fiveHour?.shownPercent == 40)
  #expect(out?.usage.sevenDay?.shownPercent == 60)
  #expect(out?.updated == now.addingTimeInterval(-100)) // nothing changed, so the age doesn't restart
}

@Test func higherNumbersAndANewWindowReplaceTheOldOnes() {
  var tracker = UsageTracker()
  _ = tracker.update(reading((40, 7200)), now: now)
  let higher = tracker.update(reading((45, 7200), updated: 50), now: now)
  #expect(higher?.usage.fiveHour?.shownPercent == 45)
  #expect(higher?.updated == now.addingTimeInterval(50))
  let fresh = tracker.update(reading((3, 7200 + 5 * 3600), updated: 99), now: now) // a later reset: a new window began
  #expect(fresh?.usage.fiveHour?.shownPercent == 3)
}

@Test func aWindowThatResetIsDroppedAndOneTheNewFileLacksIsKept() {
  var tracker = UsageTracker()
  _ = tracker.update(reading((90, 100), seven: (50, 300_000)), now: now)
  let later = now.addingTimeInterval(200) // the 5-hour window has reset by now
  let out = tracker.update(reading(seven: (51, 300_000), updated: 200), now: later)
  #expect(out?.usage.fiveHour == nil)
  #expect(out?.usage.sevenDay?.shownPercent == 51)
  let kept = tracker.update(reading(seven: (51, 300_000), updated: 260), now: later)
  #expect(kept?.usage.sevenDay?.shownPercent == 51)
}

@Test func noFileClearsTheTracker() {
  var tracker = UsageTracker()
  _ = tracker.update(reading((40, 7200)), now: now)
  #expect(tracker.update(nil, now: now) == nil)
  let after = tracker.update(reading((10, 7200), updated: 5), now: now) // not merged with what was cleared
  #expect(after?.usage.fiveHour?.shownPercent == 10)
}

@Test func hoverTextListsEachWindowAndTheAge() throws {
  let usage = try #require(PlanUsage.parse(payload(five: (83, 7800), seven: (75, 273_600)), now: now))
  #expect(usage.hoverText(now: now, updated: now.addingTimeInterval(-240)) ==
    "5-hour limit: 83% used, resets in 2h 10m\nWeekly limit: 75% used, resets in 3d 4h\nupdated 4m ago")
}

@Test func hoverTextSkipsAMissingWindow() throws {
  let usage = try #require(PlanUsage.parse(payload(seven: (10, 3600)), now: now))
  #expect(usage.hoverText(now: now, updated: now) == "Weekly limit: 10% used, resets in 1h\nupdated just now")
}
