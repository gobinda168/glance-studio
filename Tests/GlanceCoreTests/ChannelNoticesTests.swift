import Foundation
import Testing
@testable import GlanceCore

@Suite struct ChannelNoticesTests {
  private let date = Date(timeIntervalSince1970: 2_000_000)

  @Test func aMessageIsAClaudeNoticeThatOpensItsSplit() {
    let notice = ChannelNotices.message(id: "n1", label: "glance", surface: "S1", cwd: "/u/glance",
                                        title: "Tests pass", body: "42 green", date: date)
    #expect(notice.kind == .claudeMessage)
    #expect(notice.source == .claude)
    #expect(notice.title == "Tests pass")
    #expect(notice.place == "glance")
    #expect(notice.preview == "42 green")
    #expect(notice.target == .terminal(surface: "S1", cwd: "/u/glance"))
    #expect(notice.state == .unread)
  }

  @Test func anAnswerIsKeptAsRead() {
    let notice = ChannelNotices.answered(id: "n2", label: "glance", surface: nil, cwd: "/u/glance",
                                         question: "Revert?", said: "Fix forward", date: date)
    #expect(notice.preview == "You answered: Fix forward")
    #expect(notice.state == .read)
    #expect(ChannelNotices.said(.choice("Yes")) == "Yes")
    #expect(ChannelNotices.said(.allow) == "Allow")
  }

  @Test func theOrbModeFollowsThePriority() {
    #expect(ChannelBook.orbMode(state: .waiting, listening: true, speaking: true) == "listening")
    #expect(ChannelBook.orbMode(state: .waiting, listening: false, speaking: true) == "waiting")
    #expect(ChannelBook.orbMode(state: .working, listening: false, speaking: true) == "working")
    #expect(ChannelBook.orbMode(state: .done, listening: false, speaking: true) == "speaking")
    #expect(ChannelBook.orbMode(state: .done, listening: false, speaking: false) == "done")
    #expect(ChannelBook.orbMode(state: nil, listening: false, speaking: false) == nil)
  }
}
