import Foundation
import Testing
@testable import GlanceCore

@Test func theCatalogueHasTheFirstEventsAndAgentMessages() {
  #expect(AutomationEvents.all.map(\.name) == ["meeting.ended", "notice.new", "ticket.moved", "pr.ci.failed",
                                               "journal.closed", "agent.message"])
  #expect(AutomationEvents.named("agent.message")?.fields.map(\.name) == ["from", "to", "text", "hops"])
  #expect(AutomationEvents.named("meeting.ended")?.fields.map(\.name) == ["meetingID", "title", "notesPath"])
  #expect(AutomationEvents.named("notice.new")?.fields.map(\.name) == ["source", "title", "url"])
  #expect(AutomationEvents.named("ticket.moved")?.fields.map(\.name) == ["key", "from", "to"])
  #expect(AutomationEvents.named("pr.ci.failed")?.fields.map(\.name) == ["repo", "number", "sha"])
  #expect(AutomationEvents.named("pr.ci.failed")?.field("number")?.type == "number")
  #expect(AutomationEvents.named("journal.closed")?.fields.map(\.name) == ["date"])
  #expect(AutomationEvents.named("pr.merged") == nil)
  #expect(AutomationEvents.all.allSatisfy { !$0.description.isEmpty && $0.fields.allSatisfy { !$0.description.isEmpty } })
}

@Test func theCatalogueRendersAsMarkdown() {
  let text = AutomationEvents.markdown()
  #expect(text.hasPrefix("# Glance events\n"))
  #expect(text.contains("## `pr.ci.failed`"))
  #expect(text.contains("| `number` | number | The pull request's number. |"))
}

@Test func aJSONObjectLineIsAnEvent() {
  #expect(WatcherLine.parse(#"{"repo": "acme/app", "number": 412}"#)
    == .event(.object(["repo": .string("acme/app"), "number": .number(412)])))
  #expect(WatcherLine.parse("  {\"a\": 1}\r") == .event(.object(["a": .number(1)])))
}

@Test func otherLinesAreSkippedWithAReason() {
  #expect(WatcherLine.parse("") == .skipped("an empty line"))
  #expect(WatcherLine.parse("checking acme/app…") == .skipped("not JSON: checking acme/app…"))
  #expect(WatcherLine.parse("[1, 2]") == .skipped("not a JSON object: [1, 2]"))
  #expect(WatcherLine.parse("42") == .skipped("not a JSON object: 42"))
  guard case .skipped(let reason) = WatcherLine.parse(String(repeating: "x", count: 200)) else {
    Issue.record("expected a skip")
    return
  }
  #expect(reason.hasSuffix("…"))
}

@Test func theBufferSplitsChunksIntoLines() {
  var buffer = WatcherLineBuffer()
  #expect(buffer.append(Data(#"{"a":"#.utf8)).isEmpty)
  #expect(buffer.append(Data("1}\r\n{\"b\":2}\nhalf".utf8)) == [#"{"a":1}"#, #"{"b":2}"#])
  #expect(buffer.finish() == ["half"])
  #expect(buffer.finish().isEmpty)
}

@Test func aRunawayLineIsCut() {
  var buffer = WatcherLineBuffer()
  let lines = buffer.append(Data(repeating: UInt8(ascii: "x"), count: WatcherLineBuffer.limit + 10))
  #expect(lines.map(\.count) == [WatcherLineBuffer.limit])
  #expect(buffer.finish().map(\.count) == [10])
}

@Test func intervalsReadUnits() {
  #expect(AutomationInterval.parse("2m") == 120)
  #expect(AutomationInterval.parse("30s") == 30)
  #expect(AutomationInterval.parse("1h") == 3600)
  #expect(AutomationInterval.parse("1D") == 86_400)
  #expect(AutomationInterval.parse("45") == 45)
  #expect(AutomationInterval.parse("0s") == nil)
  #expect(AutomationInterval.parse("2 minutes") == nil)
  #expect(AutomationInterval.parse("") == nil)
}
