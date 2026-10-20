import Foundation
import Testing
@testable import GlanceCore

private func step(_ id: String, _ status: RunRecord.StepStatus, text: String = "", output: String = "",
                  tools: [String] = [], ms: Int? = nil, cost: Double? = nil) -> RunRecord.Step {
  RunRecord.Step(id: id, status: status, text: text, json: nil, output: output, tools: tools, durationMs: ms,
                 costUSD: cost)
}

private func record(_ status: RunRecord.Status, _ steps: [RunRecord.Step], parkedAt: String? = nil,
                    ended: Bool = true, version: Int = 3) -> RunRecord {
  let start = Date(timeIntervalSince1970: 1_760_000_000)
  return RunRecord(id: "2025-10-09T08-53-20.000Z", status: status, trigger: "manual", inputs: [:], version: version,
                   startedAt: start, endedAt: ended ? start.addingTimeInterval(9) : nil, steps: steps,
                   parkedAt: parkedAt)
}

@Test func runsReadInWords() {
  #expect(AutomationRunText.status(.parked) == "Waiting for you")
  #expect(AutomationRunText.status(.ok) == "Done")
  #expect(AutomationRunText.status(.interrupted) == "Interrupted")
  #expect(AutomationRunText.tone(.expired) == .failed)
  #expect(AutomationRunText.tone(.parked) == .waiting)
  #expect(AutomationRunText.duration(nil) == "")
  #expect(AutomationRunText.duration(320) == "320 ms")
  #expect(AutomationRunText.duration(4_210) == "4.2 s")
  #expect(AutomationRunText.duration(185_000) == "3 min 5 s")
  #expect(AutomationRunText.duration(3_840_000) == "1 h 4 min")
  #expect(AutomationRunText.cost(0) == "")
  #expect(AutomationRunText.cost(0.0423) == "$0.04")
  #expect(AutomationRunText.trigger("manual") == "By hand")
  #expect(AutomationRunText.trigger("automation morning-digest") == "From morning-digest")
  #expect(AutomationRunText.trigger("schedule 0 9 * * 1-5") == "Schedule 0 9 * * 1-5")
}

@Test func theResultIsTheLastAnswer() {
  #expect(AutomationRunText.result(record(.ok, [step("log", .ok, text: "{}"), step("fix", .ok, text: " Pushed a fix. "),
                                                step("comment", .skipped)])) == "Pushed a fix.")
  #expect(AutomationRunText.result(record(.failed, [step("log", .ok, text: "{}"),
                                                    step("fix", .failed, text: "error: no tests")]))
    == "error: no tests")
  #expect(AutomationRunText.result(record(.ok, [step("log", .ok)])) == nil)
}

@Test func longOutputShowsItsTail() {
  let shown = AutomationRunText.tail(String(repeating: "a", count: 25_000) + "END")
  #expect(shown.hasPrefix("…") && shown.hasSuffix("END") && shown.count == 20_001)
  #expect(AutomationRunText.tail("short") == "short")
}

@Test func aFinishedRunShowsEveryStepEvenTheOnesItNeverReached() {
  let run = record(.failed, [
    step("log", .ok, text: "{}", output: "{}", ms: 1200),
    step("fix", .failed, text: "error: no tests", output: "running\nerror: no tests", tools: ["Bash", "Edit", "Bash"],
         ms: 65_000, cost: 0.0423),
  ])
  let rows = AutomationTimeline.steps(run, manifest: AutomationSample.manifest())
  #expect(rows.map(\.id) == ["log", "fix", "comment", "digest"])
  #expect(rows.map(\.phase) == [.ok, .failed, .notRun, .notRun])
  #expect(rows.map(\.line) == ["Done in 1.2 s", "Failed in 1 min 5 s, $0.04", "Not run", "Not run"])
  #expect(rows.map(\.tone) == [.ok, .failed, .neutral, .neutral])
  #expect(rows[1].tools == ["Bash ×2", "Edit"])
  #expect(rows[0].output == nil)
  #expect(rows[1].output == "running\nerror: no tests")
  // A run of another version doesn't guess at steps it may not have had.
  #expect(AutomationTimeline.steps(record(.ok, [step("log", .ok)], version: 2), manifest: AutomationSample.manifest())
    .map(\.id) == ["log"])
}

@Test func aParkedRunWaitsAtItsStepAndTheRestHaventStarted() {
  let run = record(.parked, [step("log", .ok), step("fix", .ok)], parkedAt: "comment", ended: false)
  let rows = AutomationTimeline.steps(run, manifest: AutomationSample.manifest())
  #expect(rows.map(\.id) == ["log", "fix", "comment", "digest"])
  #expect(rows[2].phase == .waiting && rows[2].line == "Waiting for you" && rows[2].tone == .waiting)
  #expect(rows[3].line == "Not started")
  // An interrupted log that stopped while parked isn't waiting any more.
  let stopped = record(.interrupted, [step("log", .ok)], parkedAt: "comment", ended: false)
  #expect(AutomationTimeline.steps(stopped, manifest: nil).map(\.id) == ["log"])
}

@Test func historyReadsAsVersions() {
  let now = Date(timeIntervalSince1970: 1_760_000_000)
  let delete = AutomationHistoryEntry(commit: "d1d1d1d1d1", date: now, message: "Delete Fix red CI (fix-red-ci)",
                                      version: nil)
  let restore = AutomationHistoryEntry(commit: "c3c3c3c3c3", date: now.addingTimeInterval(-3600),
                                       message: "Restore Fix red CI (fix-red-ci) v2 from b2b2b2b as v4", version: 4)
  let save = AutomationHistoryEntry(commit: "b2b2b2b2b2", date: now.addingTimeInterval(-172_800),
                                    message: "Save Fix red CI (fix-red-ci) v2", version: 2)
  #expect(AutomationHistoryText.title(restore) == "Version 4")
  #expect(AutomationHistoryText.title(delete) == "Deleted")
  #expect(AutomationHistoryText.detail(save, now: now) == "Saved 2 d ago")
  #expect(AutomationHistoryText.detail(restore, now: now) == "Restored v2, 1 h ago")
  #expect(AutomationHistoryText.detail(delete, now: now) == "Deleted just now")
  #expect(!AutomationHistoryText.canRestore([restore, save], at: 0))
  #expect(AutomationHistoryText.canRestore([restore, save], at: 1))
  #expect(!AutomationHistoryText.canRestore([restore, save], at: 2))
  #expect(AutomationHistoryText.undoTarget([delete, restore, save]) == restore)
  #expect(AutomationHistoryText.undoTarget([restore, save]) == nil)
}

@Test func setupSaysEachTrigger() {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC")!
  let now = Date(timeIntervalSince1970: 1_760_000_000) // Thursday 9 October 2025, 08:53:20 UTC
  let lines = AutomationSample.manifest().triggers.map { AutomationSetupText.trigger($0, now: now, calendar: calendar) }
  #expect(lines == [
    AutomationTriggerLine(glyph: nil, title: "By hand", detail: "From this tab, the side bar, or Claude"),
    AutomationTriggerLine(glyph: .eye, title: "Watcher", detail: "steps/watch-ci.sh, every 2m"),
    AutomationTriggerLine(glyph: .clock, title: "Schedule", detail: "0 9 * * 1-5, next Thu 9 Oct 09:00"),
    AutomationTriggerLine(glyph: .folder, title: "Files", detail: "~/Downloads, matching *.pdf"),
    AutomationTriggerLine(glyph: .bolt, title: "Glance event", detail: "meeting.ended"),
  ])
  let filtered = AutomationTrigger(kind: "event", name: "ticket.moved", filter: ["to": .string("Done")])
  #expect(AutomationSetupText.trigger(filtered, now: now, calendar: calendar).detail == "ticket.moved, when to = Done")
  let streaming = AutomationTrigger(kind: "watcher", script: "steps/tail.sh")
  #expect(AutomationSetupText.trigger(streaming, now: now, calendar: calendar).detail
    == "steps/tail.sh, always running")
  #expect(AutomationSetupText.trigger(AutomationTrigger(kind: "webhook"), now: now, calendar: calendar)
    == AutomationTriggerLine(glyph: nil, title: "webhook", detail: "Glance doesn't know this kind of trigger"))
}

@Test func setupSaysWhetherTheTriggersAreOn() {
  let manifest = AutomationSample.manifest()
  var entry = AutomationEntry(id: "fix-red-ci", manifest: manifest, problems: [], approval: .approved)
  #expect(AutomationSetupText.armed(entry) == "Its triggers are on while Glance Studio runs.")
  #expect(AutomationSetupText.approval(entry) == "Approved")
  entry.enabled = false
  #expect(AutomationSetupText.armed(entry) == "Its triggers are off: it's switched off.")
  entry.enabled = true
  entry.approval = .never
  #expect(AutomationSetupText.armed(entry) == "Its triggers are off until you approve this version.")
  #expect(AutomationSetupText.approval(entry) == "Not approved yet")
  entry.approval = .changed(["Changes its triggers"])
  #expect(AutomationSetupText.approval(entry) == "Changed since you approved it")
  entry.problems = [AutomationProblem("id", "x")]
  #expect(AutomationSetupText.armed(entry) == "Its triggers are off until the problems below are fixed.")
  var manual = manifest
  manual.triggers = [AutomationTrigger(kind: "manual")]
  #expect(AutomationSetupText.armed(AutomationEntry(id: "fix-red-ci", manifest: manual, problems: []))
    == "Runs only when you start it.")
}
