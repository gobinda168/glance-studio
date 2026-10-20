import Foundation
import Testing
@testable import GlanceCore

private let gmail = SavedApp(id: "g", name: "Gmail", url: URL(string: "https://mail.google.com")!)
private let github = SavedApp(id: "h", name: "GitHub", url: URL(string: "https://github.com")!)
private func entry(_ text: String, _ title: String) -> HistoryEntry {
  HistoryEntry(url: URL(string: text)!, title: title, visits: 1, lastVisit: Date())
}

@Test func returnsRowComesFirstThenAppsTabsAndHistory() {
  let rows = AddressSuggestions.make(
    "git", apps: [gmail, github],
    tabs: [AddressSuggestions.OpenTab(id: "tab:1", title: "gitlab", url: URL(string: "https://gitlab.com")!)],
    history: [entry("https://github.com/apple/swift", "apple/swift")], engine: .duckDuckGo)
  #expect(rows.map(\.kind) == [.search, .app("h"), .tab("tab:1"), .history])
  #expect(rows.first?.title == "git")
  #expect(rows.first?.detail == "Search DuckDuckGo")
}

@Test func anAddressOpensFirstAndTheSearchComesLast() {
  let rows = AddressSuggestions.make("github.com", apps: [github], tabs: [],
                                     history: [entry("https://github.com/b", "B")], engine: .google)
  #expect(rows.first?.kind == .address)
  #expect(rows.first?.url.absoluteString == "https://github.com")
  // The app at the same address as the first row isn't listed twice.
  #expect(rows.map(\.kind) == [.address, .history, .search])
  #expect(rows.last?.url.host == "www.google.com")
}

@Test func eachAddressIsListedOnce() {
  let rows = AddressSuggestions.make(
    "mail", apps: [gmail],
    tabs: [AddressSuggestions.OpenTab(id: "tab:2", title: "Mail", url: URL(string: "https://mail.google.com/")!)],
    history: [entry("https://mail.google.com", "Inbox")], engine: .duckDuckGo)
  #expect(rows.map(\.kind) == [.search, .app("g")])
}

@Test func theListStopsAtItsLimitAndKeepsTheSearch() {
  let history = (1...20).map { entry("https://site\($0).com", "Site \($0)") }
  let rows = AddressSuggestions.make("site1.com", apps: [], tabs: [], history: history, engine: .duckDuckGo, limit: 5)
  #expect(rows.count == 5)
  #expect(rows.first?.kind == .address)
  #expect(rows.last?.kind == .search)
}

@Test func blankTextSuggestsNothing() {
  #expect(AddressSuggestions.make("  ", apps: [gmail], tabs: [], history: [], engine: .duckDuckGo).isEmpty)
}
