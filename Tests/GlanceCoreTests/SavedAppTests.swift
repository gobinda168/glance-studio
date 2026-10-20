import Foundation
import Testing
@testable import GlanceCore

private let gmail = SavedApp(id: "g", name: "Gmail", url: URL(string: "https://mail.google.com")!)
private let acme = AtlassianSite.cloud(base: URL(string: "https://acme.atlassian.net")!)
private let globex = AtlassianSite(id: "globex", name: "Globex", flavor: .dataCenter,
                                   jiraURL: URL(string: "https://jira.globex.com")!, confluenceURL: nil)

@Test func plainAppsAddOnceAndKeepTheirOrder() {
  var store = SavedAppStore()
  store.add(gmail)
  let figma = store.add(SavedApp(name: "Figma", url: URL(string: "https://figma.com")!))
  let again = store.add(SavedApp(name: "Mail", url: URL(string: "https://mail.google.com")!))
  #expect(again == gmail)
  #expect(store.apps.map(\.name) == ["Gmail", "Figma"])
  store.move(id: figma.id, to: 0)
  #expect(store.apps.map(\.name) == ["Figma", "Gmail"])
  store.move(id: figma.id, to: 99)
  #expect(store.apps.map(\.name) == ["Gmail", "Figma"])
  store.rename(id: "g", to: "  Mail  ")
  store.rename(id: "g", to: "   ")
  #expect(store.app(id: "g")?.name == "Mail")
  store.setURL(id: "g", URL(string: "https://mail.google.com/u/1")!)
  #expect(store.app(id: "g")?.url.absoluteString == "https://mail.google.com/u/1")
  store.remove(id: "g")
  #expect(store.apps.map(\.name) == ["Figma"])
}

@Test func aPageOnASavedSiteFindsItsApp() {
  let store = SavedAppStore(apps: [gmail])
  #expect(store.plainApp(for: URL(string: "https://MAIL.google.com/mail/u/0/#inbox")!) == gmail)
  #expect(store.plainApp(for: URL(string: "https://google.com")!) == nil)
}

@Test func savedAppsRoundTrip() {
  var store = SavedAppStore(apps: [gmail])
  store.add(SavedApp(id: "s", name: "Acme", url: URL(string: "https://app.slack.com/client/T1")!,
                     addOn: .slack(teamID: "T1")))
  store.add(SavedApp(id: "j", name: "Jira", url: URL(string: "https://acme.atlassian.net")!,
                     addOn: .atlassian(siteID: "a", product: .jira)))
  #expect(SavedAppStore(data: store.encoded()) == store)
  #expect(SavedAppStore(data: nil).apps.isEmpty)
  #expect(SavedAppStore(data: Data("not json".utf8)).apps.isEmpty)
}

@Test func aDamagedEntryIsDroppedAndTheRestKept() {
  let good = String(decoding: SavedAppStore(apps: [gmail]).encoded(), as: UTF8.self)
  let entry = good.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst().dropLast()
  let json = "[\(entry), {\"id\": 3, \"name\": null}, {\"id\": \"x\", \"name\": \"X\", \"url\": \"https://x.com\"}]"
  #expect(SavedAppStore(data: Data(json.utf8)).apps.map(\.id) == ["g"])
}

@Test func syncIsIdempotentAndFollowsTheAddOnStores() {
  var store = SavedAppStore(apps: [gmail])
  let slack = [ChatWorkspace(teamID: "T1", name: "Acme", iconURL: nil)]
  let changed1 = store.sync(slack: slack, atlassian: [acme, globex])
  #expect(changed1)
  #expect(store.apps.map(\.name) == ["Gmail", "Acme", "Jira · acme", "Jira · Globex", "Confluence"])
  #expect(store.app(addOn: .slack(teamID: "T1"))?.url.absoluteString == "https://app.slack.com/client/T1")
  #expect(store.app(addOn: .atlassian(siteID: acme.id, product: .confluence))?.url.absoluteString
    == "https://acme.atlassian.net/wiki")
  let once = store
  let changed2 = store.sync(slack: slack, atlassian: [acme, globex])
  #expect(!changed2)
  #expect(store == once)

  // A renamed workspace renames its tile; a removed site drops its tiles; plain apps stay.
  let changed3 = store.sync(slack: [ChatWorkspace(teamID: "T1", name: "Acme Corp", iconURL: nil)], atlassian: [acme])
  #expect(changed3)
  #expect(store.apps.map(\.name) == ["Gmail", "Acme Corp", "Jira", "Confluence"])
  let changed4 = store.sync(slack: [], atlassian: [])
  #expect(changed4)
  #expect(store.apps == [gmail])
}

@Test func onlyALeadingPositiveCountIsABadge() {
  #expect(TitleBadge.count("(3) Inbox") == 3)
  #expect(TitleBadge.count("  (12) Slack") == 12)
  #expect(TitleBadge.count("(99+) Inbox") == 99)
  for title in ["(abc) Inbox", "Inbox (3)", "(0) Inbox", "()", "", "(-2) x", "(3 Inbox"] {
    #expect(TitleBadge.count(title) == nil, "\(title)")
  }
}

@Test func anAppsInitialIsItsNamesFirstLetter() {
  #expect(SavedApp(name: " figma", url: URL(string: "https://figma.com")!).initial == "F")
  #expect(SavedApp(name: "", url: URL(string: "https://figma.com")!).initial == "?")
}
