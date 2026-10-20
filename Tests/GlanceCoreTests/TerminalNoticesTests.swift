import Foundation
import Testing
@testable import GlanceCore

private let now = Date(timeIntervalSince1970: 1_760_000_000)

@Test func claudeCodesAlertsNeedInput() {
  let n = TerminalNotices.notice(surface: "S1", cwd: "/Users/me/Code/glance", title: "Claude Code",
                                 body: "Claude needs your permission to use Bash", at: now)
  #expect(n.kind == .claudeNeedsInput)
  #expect(n.title == "glance")
  #expect(n.place == "Claude Code")
  #expect(n.preview == "Claude needs your permission to use Bash")
  #expect(n.threadKey == "claude:S1")
  #expect(n.target == .terminal(surface: "S1", cwd: "/Users/me/Code/glance"))
}

@Test func otherTerminalAlertsAreAlerts() {
  let n = TerminalNotices.notice(surface: "S2", cwd: nil, title: "Build", body: "done in 3m", at: now)
  #expect(n.kind == .terminalAlert)
  #expect(n.title == "Build")
  #expect(n.place == "Terminal")
}

@Test func aFinishedTurnNamesItsFolder() {
  let n = TerminalNotices.finished(cwd: "/Users/me/Code/api", at: now)
  #expect(n.kind == .claudeFinished)
  #expect(n.title == "api")
  #expect(n.threadKey == "claude:/Users/me/Code/api")
  #expect(n.target == .terminal(surface: nil, cwd: "/Users/me/Code/api"))
}

@Test func notificationsSitAtTheStripsBottom() {
  #expect(SidebarMode.stripModes(enabled: [.notifications]).first == .terminal)
  #expect(!SidebarMode.stripModes(enabled: [.notifications]).contains(.notifications))
  #expect(SidebarMode.stripBottomModes(enabled: [.notifications]) == [.notifications])
  #expect(SidebarMode.stripBottomModes(enabled: []).isEmpty)
  #expect(!SettingsSection.notifications.isShown(enabled: []))
  #expect(Feature.notifications.isGA)
}
