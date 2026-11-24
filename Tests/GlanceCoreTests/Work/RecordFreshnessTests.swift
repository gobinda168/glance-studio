import Foundation
import Testing
@testable import GlanceCore

@Suite struct RecordFreshnessTests {
  let t0 = Date(timeIntervalSince1970: 100), t1 = Date(timeIntervalSince1970: 200)

  @Test func aRecordWhoseTimeIsUnchangedIsNotReadAgain() {
    let changed = RecordFreshness.changed(sessions: ["a", "b"], seen: ["a": t0, "b": t0]) { _ in t0 }
    #expect(changed.isEmpty)
  }

  @Test func onlyTheSessionWhoseRecordChangedIsRead() {
    let changed = RecordFreshness.changed(sessions: ["a", "b", "c"], seen: ["a": t0, "b": t0, "c": t0]) { $0 == "b" ? t1 : t0 }
    #expect(changed == ["b"])
  }

  @Test func aSessionNeverReadIsReadAndEachSessionIsLookedAtOnce() {
    var looked: [String] = []
    let changed = RecordFreshness.changed(sessions: ["a", "a", "b"], seen: ["b": t0]) { session in
      looked.append(session)
      return t0
    }
    #expect(changed == ["a"])
    #expect(looked == ["a", "b"])
  }

  @Test func aRecordThatAppearedOrWasRemovedCounts() {
    let none = RecordFreshness.none
    #expect(RecordFreshness.changed(sessions: ["a"], seen: ["a": none]) { _ in t1 } == ["a"])
    #expect(RecordFreshness.changed(sessions: ["a"], seen: ["a": t1]) { _ in none } == ["a"])
    #expect(RecordFreshness.changed(sessions: ["a"], seen: ["a": none]) { _ in none }.isEmpty)
  }
}
