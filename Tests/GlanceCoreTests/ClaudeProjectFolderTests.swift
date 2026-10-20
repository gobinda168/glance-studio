import Foundation
import Testing

@testable import GlanceCore

@Suite("ClaudeProjectFolder")
struct ClaudeProjectFolderTests {
  @Test func foldersAreNamedLikeClaudeCodeDoes() {
    #expect(ClaudeProjectFolder.name(for: "/Users/me/Code/glance") == "-Users-me-Code-glance")
    #expect(ClaudeProjectFolder.name(for: "/Users/me/my.app_v2") == "-Users-me-my-app-v2")
  }

  @Test func agoIsShort() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(ClaudeProjectFolder.ago(now.addingTimeInterval(-10), now: now) == "now")
    #expect(ClaudeProjectFolder.ago(now.addingTimeInterval(-300), now: now) == "5m")
    #expect(ClaudeProjectFolder.ago(now.addingTimeInterval(-7200), now: now) == "2h")
    #expect(ClaudeProjectFolder.ago(now.addingTimeInterval(-172_800), now: now) == "2d")
  }
}
