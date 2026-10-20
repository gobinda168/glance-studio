import Foundation
import Testing
@testable import GlanceCore

private func bytes(_ s: String) -> Data { Data(s.utf8) }

@Test func parsesACompleteRequest() throws {
  let raw = "POST /event HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: 7\r\n\r\n{\"a\":1}"
  guard case .complete(let req) = HTTPRequest.parse(bytes(raw)) else { Issue.record("not complete"); return }
  #expect(req.method == "POST")
  #expect(req.path == "/event")
  #expect(req.headers["content-type"] == "application/json")
  #expect(String(decoding: req.body, as: UTF8.self) == "{\"a\":1}")
}

@Test func waitsForTheRestOfTheBody() {
  let raw = "POST /event HTTP/1.1\r\nContent-Length: 10\r\n\r\n{\"a\""
  #expect(HTTPRequest.parse(bytes(raw)) == .incomplete)
  #expect(HTTPRequest.parse(bytes("GET /health HTTP/1.1\r\nHost: x")) == .incomplete)
}

@Test func rejectsMalformedOrHugeRequests() {
  #expect(HTTPRequest.parse(bytes("garbage\r\n\r\n")) == .invalid)
  #expect(HTTPRequest.parse(bytes("POST /e HTTP/1.1\r\nContent-Length: -4\r\n\r\n")) == .invalid)
  #expect(HTTPRequest.parse(bytes("POST /e HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n")) == .invalid)
}

@Test func getWithoutBodyIsComplete() {
  guard case .complete(let req) = HTTPRequest.parse(bytes("GET /health HTTP/1.1\r\nHost: x\r\n\r\n")) else {
    Issue.record("not complete"); return
  }
  #expect(req.method == "GET")
  #expect(req.body.isEmpty)
}

@Test func decodesHookEvents() throws {
  let json = #"{"session_id":"s1","transcript_path":"/Users/me/.claude/projects/p/s1.jsonl","cwd":"/w","hook_event_name":"Stop","stop_hook_active":false}"#
  let event = try JSONDecoder().decode(HookEvent.self, from: bytes(json))
  #expect(event.name == "Stop")
  #expect(event.transcriptPath == "/Users/me/.claude/projects/p/s1.jsonl")
  #expect(event.isTranscriptPathAllowed(home: "/Users/me"))
  let sneaky = HookEvent(name: "Stop", sessionID: nil, transcriptPath: "/etc/passwd", cwd: nil)
  #expect(!sneaky.isTranscriptPathAllowed(home: "/Users/me"))
  let escape = HookEvent(name: "Stop", sessionID: nil, transcriptPath: "/Users/me/.claude/projects/../x.jsonl", cwd: nil)
  #expect(!escape.isTranscriptPathAllowed(home: "/Users/me"))
}

@Test func aResponseCanBeHTML() {
  let text = String(decoding: HTTPRequest.response(status: 200, reason: "OK", body: "<p>hi</p>",
                                                   contentType: "text/html; charset=utf-8"), as: UTF8.self)
  #expect(text.contains("Content-Type: text/html; charset=utf-8\r\n"))
  #expect(text.hasSuffix("\r\n\r\n<p>hi</p>"))
}
