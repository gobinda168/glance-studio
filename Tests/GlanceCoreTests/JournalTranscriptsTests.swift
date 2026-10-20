import Foundation
import Testing
@testable import GlanceCore

private let utc = JournalDay.calendar(timeZone: TimeZone(identifier: "UTC")!)
private let october9 = JournalDay(key: "2026-10-09")!.interval(in: utc)
private let twoDays = DateInterval(start: october9.start, duration: 2 * 86_400)
private let app = "/Users/me/Code/app"

private func line(_ type: String, _ time: String, date: String = "2026-10-09", session: String = "s1", cwd: String = app,
                  content: Any, sidechain: Bool = false, meta: Bool = false) -> String {
  let object: [String: Any] = [
    "type": type, "timestamp": "\(date)T\(time):00.000Z", "sessionId": session, "cwd": cwd, "gitBranch": "main",
    "isSidechain": sidechain, "isMeta": meta, "message": ["role": type, "content": content],
  ]
  return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private func prompt(_ text: String, _ time: String, date: String = "2026-10-09", session: String = "s1",
                    cwd: String = app) -> String {
  line("user", time, date: date, session: session, cwd: cwd, content: text)
}

private func edit(_ path: String, _ time: String) -> String {
  line("assistant", time, content: [["type": "tool_use", "name": "Edit", "input": ["file_path": path]]])
}

private func toolResult(_ time: String) -> String {
  line("user", time, content: [["type": "tool_result", "content": "done"]])
}

private func title(_ text: String, session: String = "s1") -> String {
  String(decoding: try! JSONSerialization.data(withJSONObject: ["type": "ai-title", "aiTitle": text, "sessionId": session]),
         as: UTF8.self)
}

private func events(_ lines: [String], in range: DateInterval = october9, root: (String) -> String = { $0 },
                    temporary: String = "/var/folders/xy/T/") -> [JournalEvent] {
  JournalTranscripts.events(lines: lines, in: range, calendar: utc, root: root, temporary: temporary)
}

@Test func aSessionBecomesOneEventWithItsPromptsFilesAndActiveTime() {
  let found = events([
    prompt("Fix the tab bar", "10:00"), edit("\(app)/Sources/Tabs.swift", "10:05"), toolResult("10:06"),
    edit("\(app)/Sources/Tabs.swift", "10:07"), prompt("Now the tests", "10:10"), title("Tab bar fixes"),
  ])
  #expect(found.count == 1)
  let event = found[0]
  #expect(event.source == .claude)
  #expect(event.externalID == "s1:2026-10-09")
  #expect(event.title == "Tab bar fixes")
  #expect(event.project == app)
  #expect(event.detail.prompts == ["Fix the tab bar", "Now the tests"])
  #expect(event.detail.files == ["Sources/Tabs.swift"])
  #expect(event.detail.turns == 2)
  #expect(event.detail.activeMinutes == 10)
  #expect(event.detail.branch == "main")
  #expect(event.start == JournalTime.parse("2026-10-09T10:00:00Z"))
  #expect(event.end == JournalTime.parse("2026-10-09T10:10:00Z"))
}

@Test func gapsLongerThanFifteenMinutesAreNotCounted() {
  let found = events([prompt("a", "10:00"), prompt("b", "10:10"), prompt("c", "11:00"), prompt("d", "11:05")])
  #expect(found.first?.detail.activeMinutes == 15)
  #expect(found.first?.detail.spans?.count == 2)
}

@Test func aSingleMessageCountsOneMinute() {
  #expect(events([prompt("hello", "09:00")]).first?.detail.activeMinutes == 1)
}

@Test func sidechainAndMetaLinesAreSkipped() {
  let found = events([
    prompt("real", "10:00"),
    line("user", "10:30", content: "subagent work", sidechain: true),
    line("user", "10:40", content: "meta", meta: true),
  ])
  #expect(found.first?.detail.prompts == ["real"])
  #expect(found.first?.end == JournalTime.parse("2026-10-09T10:00:00Z"))
}

@Test func aSessionCrossingMidnightCountsOnBothDays() {
  let found = events([prompt("late", "23:50"), prompt("later", "00:10", date: "2026-10-10")], in: twoDays)
  #expect(found.map(\.externalID) == ["s1:2026-10-09", "s1:2026-10-10"])
  #expect(found.map(\.day.key) == ["2026-10-09", "2026-10-10"])
}

@Test func linesOutsideTheRangeAreIgnored() {
  #expect(events([prompt("yesterday", "10:00", date: "2026-10-08")]).isEmpty)
}

@Test func scratchFoldersAreSkipped() {
  #expect(events([prompt("x", "10:00", cwd: "/private/tmp/glance")]).isEmpty)
  #expect(events([prompt("x", "10:00", cwd: "/var/folders/xy/T/glance-claude")]).isEmpty)
  #expect(JournalTranscripts.isScratch("/var/folders/xy/T", temporary: "/var/folders/xy/T/"))
  #expect(!JournalTranscripts.isScratch("/Users/me/Code/tmp-tools", temporary: "/var/folders/xy/T/"))
}

@Test func promptsAreRedactedAndCut() {
  let token = "ghp_" + String(repeating: "b", count: 36)
  let long = String(repeating: "word ", count: 200)
  let found = events([prompt("push with \(token)", "10:00"), prompt(long, "10:01")])
  let prompts = found.first?.detail.prompts ?? []
  #expect(!prompts[0].contains(token))
  #expect(prompts[0].contains("‹redacted›"))
  #expect(prompts[1].count == 300)
  #expect(prompts[1].hasSuffix("…"))
}

@Test func commandWrappersAreNotPrompts() {
  let found = events([prompt("<command-name>/clear</command-name>", "10:00"), prompt("Real question", "10:01")])
  #expect(found.first?.detail.prompts == ["Real question"])
  #expect(found.first?.title == "Real question")
}

@Test func theRootMapsASubfolderToItsProject() {
  let found = events([prompt("x", "10:00", cwd: "\(app)/Sources")], root: { _ in app })
  #expect(found.first?.project == app)
}

@Test func twoSessionsAreTwoEvents() {
  let found = events([prompt("a", "10:00", session: "s1"), prompt("b", "10:00", session: "s2")])
  #expect(Set(found.map(\.externalID)) == ["s1:2026-10-09", "s2:2026-10-09"])
}

@Test func aLongFileIsReadLineByLineAcrossChunks() throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lines-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: folder) }
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let url = folder.appendingPathComponent("long.jsonl")
  let wide = String(repeating: "x", count: 100_000)
  var text = (0..<20_000).map { String(format: "%05d", $0) + String(repeating: "-", count: 45) }.joined(separator: "\n")
  text += "\n" + wide + "\nlast line without a newline"
  try Data(text.utf8).write(to: url)
  let lines = Array(LineReader(url: url))
  #expect(lines.count == 20_002)
  #expect(lines[0].hasPrefix("00000"))
  #expect(lines[19_999].hasPrefix("19999"))
  #expect(lines[20_000] == wide)
  #expect(lines.last == "last line without a newline")
  #expect(Array(LineReader(url: folder.appendingPathComponent("missing.jsonl"))).isEmpty)
}
