import Foundation
import Testing
@testable import GlanceCore

private func line(type: String = "assistant", id: String? = "msg_1", request: String? = "req_1",
                  model: String = "claude-opus-5-5", cwd: String = "/Users/me/app/src", sidechain: Bool = false,
                  usage: String = #"{"input_tokens":2,"output_tokens":145,"cache_read_input_tokens":27189,"cache_creation_input_tokens":21081,"cache_creation":{"ephemeral_5m_input_tokens":81,"ephemeral_1h_input_tokens":21000},"speed":"standard"}"#)
  -> String {
  let message = [id.map { #""id":"\#($0)""# }, #""model":"\#(model)""#, #""usage":\#(usage)"#]
    .compactMap { $0 }.joined(separator: ",")
  let request = request.map { #""requestId":"\#($0)","# } ?? ""
  return #"{"type":"\#(type)",\#(request)"isSidechain":\#(sidechain),"sessionId":"s1","cwd":"\#(cwd)","timestamp":"2026-10-09T10:15:00.000Z","message":{\#(message)}}"#
}

private func parse(_ text: String, file: String = "/t/a.jsonl", offset: Int = 0) -> UsageRecord? {
  UsageImport.record(line: text, file: file, offset: offset, root: { $0 == "/Users/me/app/src" ? "/Users/me/app" : $0 },
                     temporary: "/var/folders/xy/T/")
}

@Test func anAssistantLineBecomesOneRecord() throws {
  let record = try #require(parse(line()))
  #expect(record.messageID == "msg_1")
  #expect(record.model == "claude-opus-5-5")
  #expect(record.sessionID == "s1")
  #expect(record.project == "/Users/me/app")
  #expect(record.time == Date(timeIntervalSince1970: 1_791_540_900))
  #expect(record.input == 2)
  #expect(record.output == 145)
  #expect(record.cacheRead == 27189)
  #expect(record.cacheWrite5m == 81)
  #expect(record.cacheWrite1h == 21000)
  #expect(!record.subagent)
  #expect(!record.fast)
}

@Test func withoutTheLifetimeSplitEveryCacheWriteIsFiveMinutes() throws {
  let record = try #require(parse(line(usage: #"{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":500}"#)))
  #expect(record.cacheWrite5m == 500)
  #expect(record.cacheWrite1h == 0)
}

@Test func fastModeAndSubagentsAreMarked() throws {
  let fast = try #require(parse(line(usage: #"{"input_tokens":1,"output_tokens":1,"speed":"fast"}"#)))
  #expect(fast.fast)
  #expect(try #require(parse(line(sidechain: true))).subagent)
  #expect(try #require(parse(line(), file: "/t/proj/s1/subagents/agent-a.jsonl")).subagent)
}

@Test func theIDFallsBackToTheRequestThenTheLinesPlace() throws {
  #expect(try #require(parse(line(id: nil))).messageID == "req_1")
  #expect(try #require(parse(line(id: nil, request: nil), file: "/t/a.jsonl", offset: 812)).messageID == "/t/a.jsonl:812")
}

@Test func tempFolderSessionsAreGlancesBackgroundRuns() throws {
  #expect(try #require(parse(line(cwd: "/private/tmp/run-1"))).project == "")
  #expect(try #require(parse(line(cwd: "/var/folders/xy/T/glance-ask"))).project == "")
}

@Test func linesWithoutUsageAreSkipped() {
  #expect(parse(line(type: "user")) == nil)
  #expect(parse(line(model: "<synthetic>")) == nil)
  #expect(parse(line(usage: #"{"input_tokens":0,"output_tokens":0}"#)) == nil)
  #expect(parse(#"{"type":"summary","summary":"x"}"#) == nil)
  #expect(parse("{not json") == nil)
  #expect(parse("") == nil)
}
