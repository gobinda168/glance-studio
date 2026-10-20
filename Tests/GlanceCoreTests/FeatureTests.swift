import Testing
@testable import GlanceCore

private let everyFeature: Set<Feature> = [.browser, .agents, .automations, .tools, .journal, .cloud, .notifications, .usage, .meetingNotes, .tickets,
        .orbChannel, .needsYou, .secrets, .tabGroups, .summaries, .gsCode]

private let everyGAFeature = everyFeature.subtracting([.gsCode])

@Test func everyFeatureButGSCodeIsGA() {
  #expect(Feature.allCases.filter { !$0.isGA } == [.gsCode])
  #expect(Feature.unreleased == [.gsCode])
}

@Test func aReleaseBuildHasEveryGAFeature() {
  #expect(Feature.enabled(development: false, choices: [:]) == everyGAFeature)
  // The Develop menu's choices don't switch off a GA feature, nor on one that isn't.
  #expect(Feature.enabled(development: false, choices: [.browser: false, .tools: false, .gsCode: true])
    == everyGAFeature)
}

@Test func aDevelopmentBuildHasEveryGAFeatureWhateverTheMenuSays() {
  #expect(Feature.enabled(development: true, choices: [:]) == everyFeature)
  #expect(Feature.enabled(development: true, choices: [.browser: false, .journal: false]) == everyFeature)
  #expect(Feature.enabled(development: true, choices: [.agents: false, .tools: false, .gsCode: false]) == everyGAFeature)
}

@Test func aGAFeatureIsOnInEveryBuildWhateverTheMenuSays() {
  #expect(Feature.isOn(isGA: true, development: false, choice: nil))
  #expect(Feature.isOn(isGA: true, development: true, choice: false))
  #expect(!Feature.isOn(isGA: false, development: false, choice: true))
  #expect(Feature.isOn(isGA: false, development: true, choice: nil))
  #expect(!Feature.isOn(isGA: false, development: true, choice: false))
}

@Test func everyFeatureHasATitle() {
  #expect(Feature.allCases.map(\.title)
    == ["Browser", "Agents", "Automations", "Tools", "Journal", "Glance Cloud", "Notifications", "Usage",
        "Meeting Notes", "Tickets", "Orb Channel", "Claude Needs You", "Secrets", "Tab Groups", "Summaries", "GS Code"])
}

@Test func aSwitchSavedForChatsOrJiraAndConfluenceCountsForTheBrowser() {
  #expect(Feature.choices(saved: ["chats": false]) == [.browser: false])
  #expect(Feature.choices(saved: ["atlassian": false]) == [.browser: false])
  #expect(Feature.choices(saved: ["chats": true, "atlassian": false]) == [.browser: true])
  #expect(Feature.choices(saved: ["browser": true, "chats": false]) == [.browser: true])
  #expect(Feature.choices(saved: ["tools": false, "nonsense": true, "journal": "yes"]) == [.tools: false])
}
