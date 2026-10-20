import Testing
@testable import GlanceCore

@Suite struct OrbChannelKindTests {
  @Test func claudeMessagesAreClaudeNoticesThatNudge() {
    #expect(Notice.Kind.claudeMessage.source == .claude)
    #expect(Notice.Kind.claudeMessage.label == "Messages from Claude sessions")
    #expect(!Notice.Kind.claudeMessage.needsYou)
    #expect(NotificationPrefs.defaultNudge(.claudeMessage))
    #expect(Notice.Kind.kinds(of: .claude).contains(.claudeMessage))
  }
}
