import Foundation
import Testing
@testable import GlanceCore

private let user = #"{"type":"user","cwd":"/a","message":{"role":"user","content":"Fix the login bug"}}"#
private let tool = #"{"type":"assistant","cwd":"/a","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/a/src/login.ts"}}]}}"#
private let result = #"{"type":"user","cwd":"/a","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#
private let reply = #"{"type":"assistant","cwd":"/a","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Fixed: the token expired early."}]}}"#

@Test func aDigestKeepsPromptsRepliesAndToolLines() {
  let jsonl = [user, tool, result, reply].joined(separator: "\n") + "\n"
  let digest = TranscriptDigest.make(data: Data(jsonl.utf8), root: "/a")
  #expect(digest.turns == 1)
  #expect(digest.firstPrompt == "Fix the login bug")
  #expect(digest.text.contains("USER: Fix the login bug"))
  #expect(digest.text.contains("· Edit"))
  #expect(digest.text.contains("login.ts"))
  #expect(digest.text.contains("CLAUDE: Fixed: the token expired early."))
  #expect(!digest.text.contains("\"ok\""))
  #expect(digest.coveredBytes == jsonl.utf8.count)
}

@Test func aHalfWrittenLastLineIsLeftForNextTime() {
  let whole = user + "\n"
  let data = Data((whole + String(reply.prefix(40))).utf8)
  let digest = TranscriptDigest.make(data: data, root: nil)
  #expect(digest.coveredBytes == whole.utf8.count)
  #expect(!digest.text.contains("CLAUDE"))
}

@Test func noCompleteLineIsAnEmptyDigest() {
  let digest = TranscriptDigest.make(data: Data("{\"type\":".utf8), root: nil)
  #expect(digest == TranscriptDigest(text: "", turns: 0, coveredBytes: 0, firstPrompt: nil))
}

@Test func chunksSplitAtTurnsAndKeepEverything() {
  let text = (1...6).map { "USER: q\($0)\nCLAUDE: " + String(repeating: "x", count: 40) }.joined(separator: "\n\n")
  let chunks = TranscriptDigest.chunks(text, limit: 120)
  #expect(chunks.count > 1)
  #expect(chunks.allSatisfy { $0.hasPrefix("USER: ") })
  #expect(chunks.joined(separator: "\n\n") == text)
  #expect(TranscriptDigest.chunks("short", limit: 120) == ["short"])
}
