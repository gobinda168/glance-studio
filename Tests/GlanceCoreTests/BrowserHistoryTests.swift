import Foundation
import Testing
@testable import GlanceCore

private func freshHistory() throws -> BrowserHistory {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("browser-history-\(UUID().uuidString)")
  return try BrowserHistory(url: folder.appendingPathComponent("history.sqlite"))
}

private func url(_ text: String) -> URL { URL(string: text)! }

@Test func aVisitCountsAndKeepsItsTitle() throws {
  let history = try freshHistory()
  try history.record(url("https://github.com/apple/swift"), title: "apple/swift", at: Date(timeIntervalSince1970: 10))
  try history.record(url("https://github.com/apple/swift"), title: nil, at: Date(timeIntervalSince1970: 20))
  let entries = try history.recent(limit: 10)
  #expect(entries.count == 1)
  #expect(entries.first?.title == "apple/swift")
  #expect(entries.first?.visits == 2)
  #expect(entries.first?.lastVisit == Date(timeIntervalSince1970: 20))
  try history.setTitle("  Swift  ", for: url("https://github.com/apple/swift"))
  #expect(try history.recent(limit: 1).first?.title == "Swift")
}

@Test func onlyWebPagesAreKept() throws {
  let history = try freshHistory()
  try history.record(url("about:blank"), title: "x", at: Date())
  try history.record(url("file:///tmp/a.html"), title: "x", at: Date())
  try history.record(url("data:text/plain,hi"), title: "x", at: Date())
  #expect(try history.recent(limit: 10).isEmpty)
}

@Test func addressPrefixesComeBeforeTitlesThenVisitsThenRecency() throws {
  let history = try freshHistory()
  try history.record(url("https://www.github.com/a"), title: "Code", at: Date(timeIntervalSince1970: 1))
  try history.record(url("https://news.ycombinator.com"), title: "GitHub is down", at: Date(timeIntervalSince1970: 2))
  try history.record(url("https://github.com/b"), title: "B", at: Date(timeIntervalSince1970: 3))
  try history.record(url("https://github.com/b"), title: nil, at: Date(timeIntervalSince1970: 4))
  let matches = try history.matches("GitHub", limit: 10).map(\.url.absoluteString)
  #expect(matches == ["https://github.com/b", "https://www.github.com/a", "https://news.ycombinator.com"])
  #expect(try history.matches("www.github", limit: 10).count == 2)
  #expect(try history.matches("https://github.com/b", limit: 10).map(\.url.absoluteString) == ["https://github.com/b"])
  #expect(try history.matches("github", limit: 1).count == 1)
  #expect(try history.matches("  ", limit: 10).isEmpty)
}

@Test func wildcardsInTheTypedTextMatchLiterally() throws {
  let history = try freshHistory()
  try history.record(url("https://a.com/x"), title: "Plain", at: Date())
  try history.record(url("https://b.com/100%25"), title: "Sale 100% off", at: Date())
  #expect(try history.matches("%", limit: 10).map(\.title) == ["Sale 100% off"])
  #expect(try history.matches("_", limit: 10).isEmpty)
  #expect(try history.matches("\\", limit: 10).isEmpty)
}

@Test func clearingForgetsEverything() throws {
  let history = try freshHistory()
  try history.record(url("https://a.com"), title: "A", at: Date())
  try history.clear()
  #expect(try history.recent(limit: 10).isEmpty)
}

@Test func theBareAddressDropsSchemeAndWWW() {
  #expect(BrowserHistory.bare(url("https://WWW.GitHub.com/A")) == "github.com/a")
  #expect(BrowserHistory.bare(url("http://localhost:3000/")) == "localhost:3000/")
}
