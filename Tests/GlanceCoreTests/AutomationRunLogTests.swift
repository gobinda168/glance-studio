import Foundation
import Testing
@testable import GlanceCore

// 2026-10-09T03:30:00.125Z. Offsets are multiples of 1/8 s so every time is exact in milliseconds.
private let start = Date(timeIntervalSince1970: 1_791_516_600.125)

private func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

private let run: [RunLogLine] = [
  RunLogLine(at: at(0), event: .runStart(trigger: "event meeting.ended", payload: .object(["title": .string("Sync")]),
                                         inputs: ["repo": .string("acme/app")], version: 3)),
  RunLogLine(at: at(0.125), event: .stepStart(step: "log")),
  RunLogLine(at: at(0.25), event: .stepOutput(step: "log", chunk: "fetching…\n")),
  RunLogLine(at: at(0.375), event: .stepOutput(step: "log", chunk: "done\n")),
  RunLogLine(at: at(1), event: .stepEnd(step: "log", status: .ok, text: #"{"n":1}"#, json: .object(["n": .number(1)]),
                                        durationMs: 900, costUSD: nil)),
  RunLogLine(at: at(1.125), event: .stepStart(step: "fix")),
  RunLogLine(at: at(2), event: .stepTool(step: "fix", name: "Edit")),
  RunLogLine(at: at(3), event: .stepEnd(step: "fix", status: .ok, text: "Fixed.", json: nil, durationMs: 1900,
                                        costUSD: 0.04)),
  RunLogLine(at: at(3.125), event: .runPark(step: "comment")),
  RunLogLine(at: at(60), event: .runResume(step: "comment", decision: .approve)),
  RunLogLine(at: at(60.125), event: .stepStart(step: "comment")),
  RunLogLine(at: at(61), event: .stepEnd(step: "comment", status: .ok, text: "", json: nil, durationMs: 900,
                                         costUSD: nil)),
  RunLogLine(at: at(61.5), event: .runEnd(status: .ok)),
]

@Test func linesAreFlatSortedJSON() {
  #expect(RunLog.line(run[4])
    == #"{"at":"2026-10-09T03:30:01.125Z","durationMs":900,"event":"step.end","json":{"n":1},"status":"ok","step":"log","text":"{\"n\":1}"}"#)
  #expect(RunLog.line(run[12]) == #"{"at":"2026-10-09T03:31:01.625Z","event":"run.end","status":"ok"}"#)
}

@Test func everyEventRoundTrips() {
  let text = run.map(RunLog.line).joined(separator: "\n") + "\n"
  #expect(RunLog.decode(text) == run)
  #expect(run.map(\.event.name) == ["run.start", "step.start", "step.output", "step.output", "step.end", "step.start",
                                    "step.tool", "step.end", "run.park", "run.resume", "step.start", "step.end",
                                    "run.end"])
}

@Test func brokenLinesAreSkipped() {
  let text = RunLog.line(run[0]) + "\n\n" + #"{"at":"2026-10-09T03:30:00.120Z","event":"step.st"# + "\n"
    + #"{"at":"yesterday","event":"run.end","status":"ok"}"# + "\n"
    + #"{"at":"2026-10-09T03:30:00.120Z","event":"step.dance"}"#
  #expect(RunLog.decode(text) == [run[0]])
}

@Test func aFinishedRunSummarizes() {
  let record = RunLog.summarize(run, id: "2026-10-09T03-30-00.125Z", live: false)!
  #expect(record.status == .ok)
  #expect(record.trigger == "event meeting.ended")
  #expect(record.inputs == ["repo": .string("acme/app")])
  #expect(record.version == 3)
  #expect(record.durationMs == 61_500)
  #expect(record.steps.map(\.id) == ["log", "fix", "comment"])
  #expect(record.steps[0].output == "fetching…\ndone\n")
  #expect(record.steps[0].json == .object(["n": .number(1)]))
  #expect(record.steps[1].tools == ["Edit"])
  #expect(record.costUSD == 0.04)
  #expect(record.parkedAt == nil)
}

@Test func aLiveRunShowsWhereItIs() {
  let parked = RunLog.summarize(Array(run.prefix(9)), id: "r", live: true)!
  #expect(parked.status == .parked)
  #expect(parked.parkedAt == "comment")
  let running = RunLog.summarize(Array(run.prefix(4)), id: "r", live: true)!
  #expect(running.status == .running)
  #expect(running.steps.map(\.status) == [.running])
  #expect(running.steps[0].text == "fetching…\ndone\n")
}

// Studio quit mid-run: the log has no run.end; the run reads as interrupted, never running forever.
@Test func aRunWithNoEndThatIsntLiveWasInterrupted() {
  let record = RunLog.summarize(Array(run.prefix(6)), id: "r", live: false)!
  #expect(record.status == .interrupted)
  #expect(record.steps.map(\.status) == [.ok, .cancelled])
  #expect(record.endedAt == nil)
  #expect(RunLog.summarize(Array(run.dropFirst()), id: "r", live: false) == nil)
}

@Test func fileNamesSortByTimeAndReadBack() {
  #expect(RunLog.fileName(for: start) == "2026-10-09T03-30-00.125Z.jsonl")
  #expect(RunLog.start(ofFile: "2026-10-09T03-30-00.125Z.jsonl") == start)
  #expect(RunLog.start(ofFile: "notes.txt") == nil)
}

@Test func pruningKeepsTheNewest200WithinThirtyDays() {
  let now = start
  let recent = (0..<205).map { RunLog.fileName(for: now.addingTimeInterval(Double(-$0) * 3600)) }
  #expect(RunLog.prune(recent + ["README.md"], now: now) == Array(recent.suffix(5)))
  let old = RunLog.fileName(for: now.addingTimeInterval(-31 * 86_400))
  let fresh = RunLog.fileName(for: now.addingTimeInterval(-29 * 86_400))
  #expect(RunLog.prune([old, fresh], now: now) == [old])
}

// JSONEncoder writes U+2028, U+2029 and U+0085 raw inside strings; only "\n" ends a line.
@Test func unicodeLineSeparatorsInsideTextDoNotSplitALine() {
  let odd = "a\u{2028}b\u{2029}c\u{85}d\r"
  let lines = [
    RunLogLine(at: at(0), event: .stepOutput(step: "s", chunk: odd)),
    RunLogLine(at: at(1), event: .stepEnd(step: "s", status: .ok, text: odd, json: .string(odd), durationMs: 1,
                                          costUSD: nil)),
  ]
  let text = lines.map(RunLog.line).joined(separator: "\n") + "\n"
  #expect(RunLog.decode(text) == lines)
  #expect(RunLog.decode(text.replacingOccurrences(of: "\n", with: "\r\n")) == lines)
}

// An encode failure must not make the event vanish: non-finite numbers are written as "nan", "inf", "-inf".
@Test func nonFiniteNumbersAreStillWritten() {
  let nan = RunLogLine(at: at(0), event: .stepEnd(step: "s", status: .ok, text: "", json: nil, durationMs: 1,
                                                  costUSD: .nan))
  #expect(RunLog.line(nan).contains(#""costUSD":"nan""#))
  guard case .stepEnd(_, _, _, _, _, let cost?)? = RunLog.decode(RunLog.line(nan)).first?.event else {
    Issue.record("the nan line didn't decode")
    return
  }
  #expect(cost.isNaN)
  let inf = RunLogLine(at: at(0), event: .stepEnd(step: "s", status: .ok, text: "",
                                                  json: .object(["n": .number(-.infinity)]), durationMs: 1,
                                                  costUSD: .infinity))
  #expect(RunLog.decode(RunLog.line(inf)) == [inf])
}
