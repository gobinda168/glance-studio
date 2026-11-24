import Foundation
import GlanceCore
import Testing
@testable import GlanceKit

// The Glance view follows a transcript from its last 16 MB; the board follows many, so each starts from a smaller tail.

@Suite struct TimelineFeedTests {
  @MainActor @Test func aFeedCanStartFromASmallerTail() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("t.jsonl")
    let old = String(repeating: #"{"type":"system","subtype":"x"}"# + "\n", count: 2_000)
    let last = #"{"type":"user","uuid":"u1","timestamp":"2026-11-02T10:00:00Z","message":{"role":"user","content":"hello"}}"# + "\n"
    try Data((old + last).utf8).write(to: file)
    let feed = TimelineFeed(initialLimit: 1024)
    var seen: SessionTimeline?
    feed.onChange = { seen = $0 }
    feed.follow(file.path, root: nil)
    for _ in 0..<50 where seen == nil { try await Task.sleep(for: .milliseconds(100)) }
    feed.stop()
    #expect(seen?.truncated == true)
    #expect(seen?.rows.count == 1)
  }
}
