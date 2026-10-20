import Foundation
import Testing
@testable import GlanceCore

@Test func eachStateHasTheDesignsOrbModeAndWords() {
  #expect(PanelStatus(state: .thinking, hasReply: true) ==
    PanelStatus(mode: "thinking", header: "THINKING", title: "Thinking", subtitle: "WORKING ON AN ANSWER"))
  #expect(PanelStatus(state: .reading, hasReply: true) ==
    PanelStatus(mode: "reading", header: "READING", title: "Reading", subtitle: "SCANNING THE PAGE"))
  #expect(PanelStatus(state: .speaking, hasReply: true) ==
    PanelStatus(mode: "speaking", header: "READING ALOUD", title: "Speaking", subtitle: "READING ALOUD"))
}

@Test func idleSaysWhetherAReplyIsWaiting() {
  #expect(PanelStatus(state: .idle, hasReply: false).header == "WAITING FOR CLAUDE")
  #expect(PanelStatus(state: .idle, hasReply: true).header == "READY")
  #expect(PanelStatus(state: .idle, hasReply: true).subtitle == "READY WHEN YOU ARE")
}

@Test func pausedLooksIdleButSaysPaused() {
  let paused = PanelStatus(state: .paused, hasReply: true)
  #expect(paused.mode == "idle")
  #expect(paused.header == "PAUSED")
  #expect(paused.title == "Paused")
}

@Test func panelPrefsDefaultToTheDesign() {
  let prefs = PanelPrefs()
  #expect(prefs.theme == .dark)
  #expect(prefs.speed == 1)
  #expect(prefs.size == 1)
  #expect(prefs.animate && prefs.follow)
}

@Test func panelPrefsClampWhatThePageSends() throws {
  let json = #"{"theme":"light","speed":3,"size":9,"animate":false,"follow":true}"#
  let prefs = try JSONDecoder().decode(PanelPrefs.self, from: Data(json.utf8)).clamped()
  #expect(prefs.theme == .light)
  #expect(prefs.speed == 1.5)
  #expect(prefs.size == 2)
  #expect(!prefs.animate)
  let slow = PanelPrefs(speed: 0.1, size: -1).clamped()
  #expect(slow.speed == 0.75)
  #expect(slow.size == 0)
}

@Test func panelPrefsMissingFieldsFallBackToDefaults() throws {
  let prefs = try JSONDecoder().decode(PanelPrefs.self, from: Data(#"{"theme":"light"}"#.utf8))
  #expect(prefs == PanelPrefs(theme: .light))
}
