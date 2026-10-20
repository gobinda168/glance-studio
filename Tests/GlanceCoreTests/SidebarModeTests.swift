import Testing
@testable import GlanceCore

@Test func theStripListsTheModesWhoseFeatureIsOnInTheCanvasOrder() {
  #expect(SidebarMode.stripModes(enabled: []) == [.terminal, .editor, .pullRequests, .captures, .mods])
  #expect(SidebarMode.stripModes(enabled: [.browser, .agents, .automations, .tools, .journal]).map(\.title)
    == ["Terminal", "Editor", "Browser", "Agents", "Automations", "Pull requests", "To-dos & Notes", "Journal", "Tools", "Mods"])
  // Agents run on the automation engine: no Agents without Automations.
  #expect(SidebarMode.stripModes(enabled: [.agents, .tools]) == [.terminal, .editor, .pullRequests, .captures, .tools, .mods])
  #expect(SidebarMode.stripModes(enabled: [.agents, .automations]) == [.terminal, .editor, .agents, .automations,
                                                                       .pullRequests, .captures, .mods])
  #expect(SidebarMode.stripModes(enabled: [.journal]) == [.terminal, .editor, .pullRequests, .captures, .journal, .mods])
  #expect(SidebarMode.allCases
    == [.terminal, .editor, .browser, .agents, .automations, .pullRequests, .captures, .tickets,
        .journal, .meetings, .usage, .tools, .mods, .notifications, .settings])
  #expect(SidebarMode.settings.title == "Settings")
}

@Test func aSavedModeComesBackAndAnythingElseIsTerminal() {
  #expect(SidebarMode(saved: "pullRequests", enabled: []) == .pullRequests)
  #expect(SidebarMode(saved: "editor", enabled: []) == .editor)
  #expect(SidebarMode(saved: "settings", enabled: []) == .settings)
  #expect(SidebarMode(saved: "browser", enabled: [.browser]) == .browser)
  #expect(SidebarMode(saved: nil, enabled: []) == .terminal)
  #expect(SidebarMode(saved: "inbox", enabled: []) == .terminal)
}

@Test func aSideBarTheBrowserReplacedComesBackAsTheBrowser() {
  #expect(SidebarMode(saved: "chats", enabled: [.browser]) == .browser)
  #expect(SidebarMode(saved: "issues", enabled: [.browser]) == .browser)
  #expect(SidebarMode(saved: "docs", enabled: [.browser]) == .browser)
  #expect(SidebarMode(saved: "chats", enabled: []) == .terminal)
}

@Test func aSavedModeWhoseFeatureIsOffComesBackAsTerminal() {
  #expect(SidebarMode(saved: "browser", enabled: []) == .terminal)
  #expect(SidebarMode(saved: "agents", enabled: [.browser]) == .terminal)
  #expect(SidebarMode(saved: "automations", enabled: [.agents]) == .terminal)
  #expect(SidebarMode(saved: "tools", enabled: [.automations]) == .terminal)
}

@Test func journalComesBackOnlyWhileItsFeatureIsOn() {
  #expect(SidebarMode(saved: "journal", enabled: [.journal]) == .journal)
  #expect(SidebarMode(saved: "journal", enabled: []) == .terminal)
}

@Test func everyModeIsBuilt() {
  #expect(SidebarMode.allCases.filter(\.isBuilt) == SidebarMode.allCases)
}

@Test func everyModeHasItsCanvasIcon() {
  #expect(SidebarMode.allCases.map(\.icon)
    == [.terminal, .editor, .globe, .agents, .automations, .pullRequest, .notes, .checklist, .journal,
        .mic, .chart, .tools, .puzzle, .bell, .settings])
  #expect(SidebarMode.allCases.allSatisfy { !StudioIcons.shapes($0.icon).isEmpty })
}

@Test func theBrowserBelongsToItsFeature() {
  #expect(SidebarMode.browser.title == "Browser")
  #expect(SidebarMode.browser.feature == .browser)
  #expect(SidebarMode.stripModes(enabled: [.browser, .tickets]) == [.terminal, .editor, .browser, .pullRequests, .captures, .tickets, .mods])
}

@Test func usageIsOnTheStripAfterJournalOnlyWhileItsFeatureIsOn() {
  #expect(SidebarMode.stripModes(enabled: [.usage]) == [.terminal, .editor, .pullRequests, .captures, .usage, .mods])
  #expect(SidebarMode.stripModes(enabled: [.journal, .usage, .tools]).suffix(4) == [.journal, .usage, .tools, .mods])
  #expect(SidebarMode(saved: "usage", enabled: [.usage]) == .usage)
  #expect(SidebarMode(saved: "usage", enabled: []) == .terminal)
  #expect(SidebarMode.usage.title == "Usage")
}

@Test func meetingsSitBetweenJournalAndUsageOnlyWhileMeetingNotesIsOn() {
  #expect(SidebarMode.stripModes(enabled: [.meetingNotes]) == [.terminal, .editor, .pullRequests, .captures, .meetings, .mods])
  #expect(SidebarMode.stripModes(enabled: [.journal, .meetingNotes, .usage]).suffix(4) == [.journal, .meetings, .usage, .mods])
  #expect(SidebarMode(saved: "meetings", enabled: [.meetingNotes]) == .meetings)
  #expect(SidebarMode(saved: "meetings", enabled: []) == .terminal)
  #expect(SidebarMode.meetings.title == "Meetings")
}

@Test func toDosAndNotesAreAlwaysOnTheStripAfterPullRequests() {
  #expect(SidebarMode.stripModes(enabled: []).contains(.captures))
  #expect(SidebarMode(saved: "captures", enabled: []) == .captures)
  #expect(SidebarMode.captures.title == "To-dos & Notes")
  #expect(SidebarMode.owner(ofTabKind: "captures") == .captures)
}

@Test func modsAreAlwaysOnTheStripAfterTools() {
  #expect(SidebarMode.stripModes(enabled: []).last == .mods)
  #expect(SidebarMode(saved: "mods", enabled: []) == .mods)
  #expect(SidebarMode.mods.title == "Mods")
  #expect(SidebarMode.owner(ofTabKind: "mods") == .mods)
}
