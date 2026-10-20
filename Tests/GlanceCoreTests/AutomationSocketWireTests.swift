import Foundation
import Testing
@testable import GlanceCore

@Test func requestsRoundTrip() throws {
  let requests: [AutomationSocketRequest] = [
    .run(id: "fix-red-ci", inputs: ["repo": .string("acme/app"), "pr": .number(7)], wait: true),
    .run(id: "a", inputs: [:], wait: false),
    .runs(id: "a", run: nil, limit: 10),
    .runs(id: "a", run: "2026-10-09T09-00-00.120Z", limit: 3),
    .status,
  ]
  for request in requests {
    #expect(!request.line.contains("\n"))
    #expect(try AutomationSocketRequest.parse(request.line).get() == request)
  }
}

// Review focus: whatever reaches the socket, Studio acts only on a well-formed request for a real id.
@Test func badRequestsAreRefused() throws {
  for line in ["", "nope", "[1]", #"{"op":"run"}"#, #"{"op":"run","id":"../x"}"#, #"{"op":"delete","id":"a"}"#,
               #"{"op":"runs","id":"a","run":"../../approvals.json"}"#] {
    guard case .failure = AutomationSocketRequest.parse(line) else {
      Issue.record("accepted \(line)")
      continue
    }
  }
  #expect(try AutomationSocketRequest.parse(#"{"op":"runs","id":"a","limit":500}"#).get()
    == .runs(id: "a", run: nil, limit: 50))
}

@Test func responsesRoundTrip() {
  for response: AutomationSocketResponse in [.ok(.object(["status": .string("ok")])), .failed("Approve Fix first.")] {
    #expect(AutomationSocketResponse.parse(response.line) == response)
  }
  #expect(AutomationSocketResponse.parse("garbage") == .failed("Glance Studio sent something unreadable."))
}

@Test func theSocketLivesInGlancesFolderUnlessOverridden() {
  #expect(AutomationSocketWire.path(environment: [:], home: "/Users/riya")
    == "/Users/riya/Library/Application Support/Glance/automations.sock")
  #expect(AutomationSocketWire.path(environment: ["GLANCE_AUTOMATIONS_SOCKET": "/tmp/a.sock"], home: "/Users/riya")
    == "/tmp/a.sock")
  #expect(AutomationSocketWire.fits("/Users/riya/Library/Application Support/Glance/automations.sock"))
  #expect(!AutomationSocketWire.fits("/" + String(repeating: "x", count: 103)))
}

private func step(_ id: String, _ status: RunRecord.StepStatus, _ text: String) -> RunRecord.Step {
  RunRecord.Step(id: id, status: status, text: text, json: nil, output: text, tools: [], durationMs: 5, costUSD: nil)
}

@Test func runResultsCarryTheStepsAndAParkedStep() {
  let start = Date(timeIntervalSince1970: 1_760_000_000)
  var record = RunRecord(id: "2026-10-09T09-00-00.120Z", status: .ok, trigger: "claude", inputs: [:], version: 2,
                         startedAt: start, endedAt: start.addingTimeInterval(3),
                         steps: [step("log", .ok, "red"), step("fix", .ok, String(repeating: "x", count: 5000))],
                         parkedAt: nil)
  let ended = AutomationSocketWire.runResult(record).object
  #expect(ended?["status"] == .string("ok"))
  #expect(ended?["run"] == .string("2026-10-09T09-00-00.120Z"))
  guard case .array(let steps)? = ended?["steps"] else {
    Issue.record("no steps")
    return
  }
  #expect(steps.first == .object(["id": .string("log"), "status": .string("ok"), "text": .string("red")]))
  #expect(steps.last?.object?["text"]?.text.hasSuffix("[cut: the run log has all of it]") == true)
  record.status = .parked
  record.parkedAt = "comment"
  let parked = AutomationSocketWire.runResult(record).object
  #expect(parked?["status"] == .string("parked"))
  #expect(parked?["step"] == .string("comment"))
  #expect(parked?["message"] == .string("Waiting for the user's approval of `comment` in Glance Studio."))
  #expect(AutomationSocketWire.queued(1).object?["status"] == .string("queued"))
  #expect(AutomationSocketWire.running(AutomationRunRef(automation: "a", run: "r")).object?["run"] == .string("r"))
  let list = AutomationSocketWire.runsResult([record])
  #expect(list == .array([.object(["run": .string("2026-10-09T09-00-00.120Z"), "status": .string("parked"),
                                   "trigger": .string("claude"), "startedAt": .string("2025-10-09T08:53:20.000Z"),
                                   "durationMs": .number(3000), "version": .number(2)])]))
  #expect(AutomationSocketWire.runDetail(record).object?["trigger"] == .string("claude"))
}
