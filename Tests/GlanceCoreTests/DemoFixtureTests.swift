import Foundation
import Testing
@testable import GlanceCore

/// The whole core pipeline over the demo transcript: transcript → blocks → speech → diagram timing.
@Test func demoTranscriptBecomesANarratedReply() throws {
  let url = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/demo.jsonl")
  let reply = try #require(Transcript.lastReply(jsonl: String(contentsOf: url, encoding: .utf8)))
  let blocks = Blocks.split(reply)
  #expect(blocks.map(\.kind) == [.paragraph, .mermaid, .paragraph, .heading, .mermaid, .paragraph, .code, .paragraph])

  let spoken = blocks.enumerated().compactMap { index, block in Speech.text(for: block).map { (index, $0) } }
  #expect(spoken.map(\.0) == [0, 2, 3, 5, 7])
  #expect(spoken[1].1.contains("posts the email and password to login.ts"))
  #expect(spoken[1].1.contains("issueTokens signs"))

  #expect(Narration.diagramAnchors(blocks: blocks, spokenBlocks: spoken.map(\.0)) == [2: [1], 5: [4]])
}
