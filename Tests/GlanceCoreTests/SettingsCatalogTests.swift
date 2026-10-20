import Testing
@testable import GlanceCore

@Test func aWordOfTheNameStartingWithTheTextComesFirst() {
  let names = SettingsCatalog.search("font").map(\.name)
  #expect(names.prefix(2) == ["Font family", "Font size"])
}

@Test func keywordsFindWhatNoNameSays() {
  #expect(SettingsCatalog.search("speech").first?.id == "voice.voice")
  #expect(SettingsCatalog.search("typeface").map(\.id) == ["terminal.font"])
  #expect(SettingsCatalog.search("read aloud").map(\.id).contains("voice.voice"))
}

@Test func namesContainingTheTextComeAfterWordStarts() {
  // "home" starts a word of "Show Home at launch"; "ome" only sits inside it.
  #expect(SettingsCatalog.search("home").first?.id == "general.home")
  #expect(SettingsCatalog.search("ome").map(\.id).contains("general.home"))
}

@Test func claudeFindsItsLaunchSwitch() {
  #expect(SettingsCatalog.search("claude").first?.id == "general.claude")
}

@Test func emptyTextFindsNothingAndResultsStopAtTwelve() {
  #expect(SettingsCatalog.search("  ").isEmpty)
  #expect(SettingsCatalog.search("e").count == 12)
  #expect(SettingsCatalog.search("zzz").isEmpty)
}

@Test func everyEntryHasAUniqueIdInItsSection() {
  let ids = SettingsCatalog.entries.map(\.id)
  #expect(Set(ids).count == ids.count)
  #expect(SettingsCatalog.entries.allSatisfy { $0.id.hasPrefix($0.section.rawValue + ".") })
}

@Test func pullRequestsFindsTheAutoClaudeSwitch() {
  #expect(SettingsCatalog.search("review").map(\.id).contains("general.pullRequestsClaude"))
  #expect(SettingsCatalog.search("drafts").map(\.id).contains("general.pullRequestsClaude"))
  #expect(SettingsCatalog.search("claude").first?.id == "general.claude")
}

@Test func suggestionsAreFoundByWhatPeopleCallThem() {
  #expect(SettingsCatalog.search("autocomplete").map(\.id) == ["suggestions.tab"])
  #expect(SettingsCatalog.search("intellisense").map(\.id) == ["suggestions.tab"])
  #expect(Set(SettingsCatalog.search("history").map(\.id))
    .isSuperset(of: ["suggestions.up", "suggestions.search", "suggestions.record", "suggestions.import"]))
  #expect(SettingsCatalog.search("ctrl-r").first?.id == "suggestions.search")
}

@Test func meetingsAreFoundByWhatPeopleCallThem() {
  #expect(SettingsCatalog.search("zoom").map(\.id).contains("meetings.enabled"))
  #expect(SettingsCatalog.search("google meet").first?.id == "meetings.enabled")
  #expect(SettingsCatalog.search("calendar").map(\.id).contains("meetings.access"))
  #expect(SettingsCatalog.search("announce").first?.id == "meetings.speak")
  #expect(SettingsCatalog.search("test nudge").first?.id == "meetings.test")
  #expect(SettingsCatalog.search("google").map(\.id).contains("meetings.google"))
  #expect(SettingsCatalog.search("rsvp").first?.id == "meetings.google")
  #expect(SettingsCatalog.search("preview").map(\.id).contains("meetings.test"))
}

@Test func journalSettingsAreFoundByWhatPeopleCallThem() {
  #expect(SettingsCatalog.search("diary").first?.id == "journal.enabled")
  #expect(SettingsCatalog.search("journal").first?.id == "journal.enabled")
  #expect(SettingsCatalog.search("end of day").first?.id == "journal.wrapUp")
  #expect(SettingsCatalog.search("markdown").map(\.id).contains("journal.export"))
  #expect(SettingsCatalog.search("erase").map(\.id).contains("journal.delete"))
  #expect(SettingsCatalog.search("github").map(\.id).contains("journal.sources"))
}

@Test func signingInFindsTheAccount() {
  #expect(SettingsCatalog.search("sign in").map(\.id).contains("account.signIn"))
  #expect(SettingsCatalog.search("login").first?.id == "account.signIn")
}

@Test func meetingNotesSettingsAreFound() {
  #expect(SettingsCatalog.search("parakeet").first?.id == "meetings.notesModel")
  #expect(SettingsCatalog.search("keep recordings").first?.id == "meetings.notesKeepAudio")
  #expect(SettingsCatalog.search("meeting notes").map(\.id).contains("meetings.notesOffer"))
  #expect(SettingsCatalog.search("huddle").first?.id == "meetings.notesCalls")
}

@Test func jiraAndConfluenceSettingsAreFoundByTheirProducts() {
  #expect(SettingsCatalog.search("jira").map(\.id).contains("connectors.sites"))
  #expect(SettingsCatalog.search("confluence").map(\.id).contains("connectors.sites"))
  #expect(SettingsCatalog.search("api token").map(\.id).contains("connectors.token"))
  #expect(SettingsCatalog.search("personal access token").map(\.id).contains("connectors.token"))
}

@Test func orbChannelSettingsAreFoundByWhatPeopleCallThem() {
  // Earlier sections list "mcp" and "parakeet" too (Slack replies, the meeting notes model), so these only need to appear.
  #expect(SettingsCatalog.search("mcp").map(\.id).contains("orbChannel.enabled"))
  #expect(SettingsCatalog.search("approve").first?.id == "orbChannel.approvals")
  #expect(SettingsCatalog.search("assistant").first?.id == "orbChannel.assistant")
  #expect(SettingsCatalog.search("parakeet").map(\.id).contains("orbChannel.voice"))
  #expect(SettingsCatalog.search("speech").first?.id == "voice.voice")
}

@Test func browserSettingsAreFoundByWhatPeopleCallThem() {
  #expect(SettingsCatalog.search("duckduckgo").map(\.id).contains("browser.search"))
  #expect(SettingsCatalog.search("search engine").map(\.id).contains("browser.search"))
  #expect(SettingsCatalog.search("history").map(\.id).contains("browser.history"))
  #expect(SettingsCatalog.search("cookies").map(\.id).contains("browser.siteData"))
  #expect(SettingsCatalog.search("sign out").map(\.id).contains("browser.siteData"))
  #expect(SettingsCatalog.search("dev server").first?.id == "browser.devServers")
  #expect(SettingsCatalog.search("localhost").map(\.id).contains("browser.devServers"))
  #expect(SettingsCatalog.search("vite").map(\.id).contains("browser.devServers"))
}

@Test func secretsAreFoundByWhatPeopleCallThem() {
  for word in ["token", "api key", "credential", "password", "vault"] {
    #expect(SettingsCatalog.search(word).map(\.id).contains("secrets.list"), "\(word)")
  }
  #expect(SettingsCatalog.search("recent use").first?.id == "secrets.recent")
}
