import Testing
@testable import GlanceCore

@Test func aReadPageHasNothingUnread() {
  let title = SlackTitle("general (Channel) - Acme - Slack")
  #expect(title == SlackTitle(mentions: 0, unread: false, workspace: "Acme"))
}

@Test func aStarOrBulletMeansUnread() {
  #expect(SlackTitle("* general (Channel) - Acme - Slack") == SlackTitle(mentions: 0, unread: true, workspace: "Acme"))
  #expect(SlackTitle("• general (Channel) - Acme - Slack") == SlackTitle(mentions: 0, unread: true, workspace: "Acme"))
}

@Test func aCountOrBangMeansMentions() {
  #expect(SlackTitle("(3) general (Channel) - Acme - Slack") == SlackTitle(mentions: 3, unread: true, workspace: "Acme"))
  #expect(SlackTitle("! general (Channel) - Acme - Slack") == SlackTitle(mentions: 1, unread: true, workspace: "Acme"))
  #expect(SlackTitle("(12) * Ada (DM) - Acme - Slack").mentions == 12)
}

@Test func theOlderBarFormatNamesTheWorkspaceLast() {
  #expect(SlackTitle("Slack | general | Acme") == SlackTitle(mentions: 0, unread: false, workspace: "Acme"))
  #expect(SlackTitle("* Slack | general | Acme") == SlackTitle(mentions: 0, unread: true, workspace: "Acme"))
}

@Test func workspaceNamesKeepTheirOwnSeparators() {
  #expect(SlackTitle("general (Channel) - Acme - EU - Slack").workspace == "Acme - EU")
  #expect(SlackTitle("Slack | general | R|D").workspace == "R|D")
}

@Test func anythingElseHasNoUnreadAndNoName() {
  #expect(SlackTitle("") == SlackTitle(mentions: 0, unread: false, workspace: nil))
  #expect(SlackTitle("Slack") == SlackTitle(mentions: 0, unread: false, workspace: nil))
  #expect(SlackTitle("Sign in | Slack").workspace == nil)
  #expect(SlackTitle("(abc) something").mentions == 0)
}

@Test func theProbesTitlesParse() {
  // The titles recorded under "Verified mechanism" in the spec (S0 probe, 2026-10-09).
  #expect(SlackTitle("general (Channel) - EngageHub - Slack")
    == SlackTitle(mentions: 0, unread: false, workspace: "EngageHub"))
  #expect(SlackTitle("Slack") == SlackTitle(mentions: 0, unread: false, workspace: nil))
  #expect(SlackTitle("Log in | Slack") == SlackTitle(mentions: 0, unread: false, workspace: nil))
}
