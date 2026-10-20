import Testing
@testable import GlanceCore

@Test func settingsSectionsInTheSideBarsOrder() {
  #expect(SettingsSection.allCases == [.account, .connectors, .general, .terminal, .suggestions, .voice, .dictation, .editor, .overlay, .meetings,
                                     .browser, .notifications, .orbChannel, .secrets, .tickets, .journal])
  #expect(SettingsSection.allCases.map(\.title)
    == ["Account", "Connectors", "General", "Terminal", "Suggestions", "Voice", "Dictation", "Editor", "Overlay", "Meetings", "Browser", "Notifications", "Orb Channel", "Secrets",
       "Tickets", "Journal"])
  #expect(SettingsSection.allCases.allSatisfy { !$0.line.isEmpty && !StudioIcons.shapes($0.icon).isEmpty })
}

@Test func onlyTerminalVoiceAndDictationHaveAPreview() {
  #expect(SettingsSection.allCases.filter(\.hasPreview) == [.terminal, .voice, .dictation])
}

@Test func theLastSectionComesBackElseGeneral() {
  #expect(SettingsSection(saved: "voice") == .voice)
  #expect(SettingsSection(saved: nil) == .general)
  #expect(SettingsSection(saved: "keys") == .general)
}

@Test func journalSettingsShowOnlyWhileTheFeatureIsOn() {
  #expect(SettingsSection.journal.feature == .journal)
  #expect(!SettingsSection.journal.isShown(enabled: []))
  #expect(SettingsSection.journal.isShown(enabled: [.journal]))
  #expect(SettingsSection.allCases.filter { $0 != .journal && $0 != .account && $0 != .notifications && $0 != .tickets && $0 != .browser && $0 != .orbChannel && $0 != .secrets }.allSatisfy { $0.isShown(enabled: []) })
  #expect(SettingsSection.journal.icon == .journal)
  #expect(!SettingsSection.journal.hasPreview)
}

@Test func accountShowsOnlyWithGlanceCloud() {
  #expect(SettingsSection.account.feature == .cloud)
  #expect(!SettingsSection.account.isShown(enabled: []))
  #expect(SettingsSection.account.isShown(enabled: [.cloud]))
  #expect(SettingsSection.account.icon == .person)
  #expect(!SettingsSection.account.hasPreview)
  // A fresh install still opens on General.
  #expect(SettingsSection(saved: nil) == .general)
}

@Test func browserSettingsShowOnlyWithTheBrowser() {
  #expect(SettingsSection.browser.feature == .browser)
  #expect(!SettingsSection.browser.isShown(enabled: []))
  #expect(SettingsSection.browser.isShown(enabled: [.browser]))
  #expect(SettingsSection.browser.title == "Browser")
  #expect(SettingsSection.browser.line == "Search, history and site data.")
  #expect(SettingsSection.browser.icon == .globe)
  #expect(!SettingsSection.browser.hasPreview)
  // The section saved before it was renamed.
  #expect(SettingsSection(saved: "atlassian") == .browser)
}

@Test func orbChannelSettingsShowOnlyWithTheFeature() {
  #expect(SettingsSection.orbChannel.feature == .orbChannel)
  #expect(!SettingsSection.orbChannel.isShown(enabled: []))
  #expect(SettingsSection.orbChannel.icon == .reply)
}

@Test func secretsSettingsShowOnlyWithSecrets() {
  #expect(SettingsSection.secrets.feature == .secrets)
  #expect(!SettingsSection.secrets.isShown(enabled: []))
  #expect(SettingsSection.secrets.isShown(enabled: [.secrets]))
  #expect(SettingsSection.secrets.title == "Secrets")
  #expect(SettingsSection.secrets.line == "Tokens Claude can use but never see.")
  #expect(SettingsSection.secrets.icon == .lock)
  #expect(!SettingsSection.secrets.hasPreview)
}

@Test func connectorsIsInEveryBuild() {
  #expect(SettingsSection.connectors.feature == nil)
  #expect(SettingsSection.connectors.icon == .plug)
  #expect(SettingsCatalog.entries.contains { $0.id == "connectors.sites" && $0.section == .connectors })
}
