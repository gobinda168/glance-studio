import Testing
@testable import GlanceCore

private func shows(wantsVisible: Bool = false, terminalFront: Bool = true, forcedByHotkey: Bool = false,
                   overEditor: Bool = false, alwaysOverTerminals: Bool = true, dismissed: Bool = false) -> Bool {
  OverlayVisibility.showsPanel(wantsVisible: wantsVisible, terminalFront: terminalFront, forcedByHotkey: forcedByHotkey,
                               overEditor: overEditor, alwaysOverTerminals: alwaysOverTerminals, dismissed: dismissed)
}

@Test func alwaysShownOverATerminalWithoutAReply() {
  #expect(shows())
}

@Test func offWaitsForAReplyOrTheHotKey() {
  #expect(!shows(alwaysOverTerminals: false))
  #expect(shows(wantsVisible: true, alwaysOverTerminals: false))
}

@Test func editorsKeepTheOrbUntilItIsClicked() {
  #expect(!shows(overEditor: true))
  #expect(shows(wantsVisible: true, overEditor: true))
}

@Test func closingItHidesItUntilTheNextReply() {
  #expect(!shows(dismissed: true))
  #expect(shows(wantsVisible: true, dismissed: true))
}

@Test func otherAppsInFrontHideItUnlessTheHotKeyAskedForIt() {
  #expect(!shows(terminalFront: false))
  #expect(shows(wantsVisible: true, terminalFront: false, forcedByHotkey: true))
}
