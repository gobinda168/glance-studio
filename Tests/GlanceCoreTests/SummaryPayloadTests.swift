import Foundation
import Testing
@testable import GlanceCore

private let rec = SummaryRecord(sessionID: "s", transcriptPath: "/t", cwd: "/a", title: "Fix login", coveredBytes: 1,
                                coveredTurns: 14, headHash: "h", promptVersion: 1, summary: "## Goal\nFix it",
                                updatedAt: Date(timeIntervalSince1970: 1000))

@Test func aReadyPayloadCarriesBlocksAndFreshness() {
  let p = SummaryPayload.make(kind: .ready, record: rec, stale: true, message: nil, mode: .manual,
                              now: Date(timeIntervalSince1970: 1180))
  #expect(p["state"] as? String == "ready")
  #expect(p["title"] as? String == "Fix login")
  #expect(p["meta"] as? String == "up to turn 14 · 3 min ago")
  #expect(p["stale"] as? Bool == true)
  #expect((p["blocks"] as? [[String: Any]])?.isEmpty == false)
}

@Test func anEmptyManualPayloadOffersToSummarize() {
  let p = SummaryPayload.make(kind: .none, record: nil, stale: false, message: nil, mode: .manual, now: Date())
  #expect(p["state"] as? String == "none")
  #expect(p["hint"] as? String == "Summarizing reads this session once with Haiku. Nothing runs until you ask.")
  #expect(p["blocks"] == nil)
}

@Test func ageReadsInMinutesHoursAndDays() {
  let now = Date(timeIntervalSince1970: 100_000)
  #expect(SummaryPayload.ago(now.addingTimeInterval(-20), now: now) == "just now")
  #expect(SummaryPayload.ago(now.addingTimeInterval(-7200), now: now) == "2 h ago")
  #expect(SummaryPayload.ago(now.addingTimeInterval(-3 * 86400), now: now) == "3 d ago")
}
