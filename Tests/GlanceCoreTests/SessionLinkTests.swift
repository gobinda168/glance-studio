import Foundation
import Testing
@testable import GlanceCore

private let home = "/Users/me"
private let surface = "11111111-2222-3333-4444-555555555555"

private func payload(event: String = "SessionStart", path: String = "/Users/me/.claude/projects/-a/s1.jsonl") -> Data {
  Data(#"{"hook_event_name":"\#(event)","session_id":"s1","transcript_path":"\#(path)","cwd":"/a","source":"clear"}"#.utf8)
}

@Test func aSessionStartFileLinksItsSurface() {
  let link = SessionLink.parse(fileName: "\(surface).json", data: payload(), home: home)
  #expect(link == SessionLink(surface: UUID(uuidString: surface)!, sessionID: "s1",
                              transcriptPath: "/Users/me/.claude/projects/-a/s1.jsonl", cwd: "/a", source: "clear"))
}

@Test func linkFilesThatArentSafeAreIgnored() {
  #expect(SessionLink.parse(fileName: "not-a-uuid.json", data: payload(), home: home) == nil)
  #expect(SessionLink.parse(fileName: ".\(surface).123", data: payload(), home: home) == nil) // a temp file mid-write
  #expect(SessionLink.parse(fileName: "\(surface).json", data: payload(event: "Stop"), home: home) == nil)
  #expect(SessionLink.parse(fileName: "\(surface).json", data: payload(path: "/etc/passwd"), home: home) == nil)
  #expect(SessionLink.parse(fileName: "\(surface).json",
                            data: payload(path: "/Users/me/.claude/projects/../../x.jsonl"), home: home) == nil)
  #expect(SessionLink.parse(fileName: "\(surface).json", data: Data("{".utf8), home: home) == nil)
}
