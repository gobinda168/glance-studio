import Foundation
import Testing
@testable import GlanceCore

@Test func theColumnIsOffForRelease() {
  #expect(Feature.browserColumn.isGA == false)
  #expect(Feature.browserColumn.title == "Browser Column")
}

@Test func widthDefaultsTo42PercentOfTheSpace() {
  #expect(BrowserColumnLayout.width(saved: nil, space: 1000) == 420)
}

@Test func widthClampsToTheSpace() {
  // Never under 320, never leaving the terminal under 300.
  #expect(BrowserColumnLayout.width(saved: 100, space: 1200) == 320)
  #expect(BrowserColumnLayout.width(saved: 1100, space: 1200) == 900)
  #expect(BrowserColumnLayout.width(saved: 500, space: 1200) == 500)
  // Too little space for both: the column keeps its minimum (it overlays then).
  #expect(BrowserColumnLayout.width(saved: 500, space: 500) == 320)
}

@Test func overlaysBelowBothMinimums() {
  #expect(BrowserColumnLayout.overlays(space: 619))
  #expect(!BrowserColumnLayout.overlays(space: 620))
}

@Test func addingATabPutsItAfterTheSelectedOneAndSelectsIt() {
  var tabs = BrowserColumnTabs(first: 1)
  tabs.add(2)
  tabs.select(1)
  tabs.add(3)
  #expect(tabs.ids == [1, 3, 2])
  #expect(tabs.selected == 3)
}

@Test func closingTheSelectedTabSelectsItsRightNeighbourElseItsLeft() {
  var tabs = BrowserColumnTabs(ids: [1, 2, 3], selected: 2)!
  let result1 = tabs.close(2)
  #expect(result1)
  #expect(tabs.selected == 3)
  let result2 = tabs.close(3)
  #expect(result2)
  #expect(tabs.selected == 1)
}

@Test func theLastTabDoesNotClose() {
  var tabs = BrowserColumnTabs(first: 7)
  let result = tabs.close(7)
  #expect(!result)
  #expect(tabs.ids == [7])
}

@Test func closingAnotherTabKeepsTheSelection() {
  var tabs = BrowserColumnTabs(ids: [1, 2, 3], selected: 3)!
  let result1 = tabs.close(1)
  #expect(result1)
  #expect(tabs.selected == 3)
  let result2 = tabs.close(9)
  #expect(!result2)
}

@Test func anUnknownSelectionFallsBackToTheFirstTab() {
  #expect(BrowserColumnTabs(ids: [4, 5], selected: 9)?.selected == 4)
  #expect(BrowserColumnTabs<Int>(ids: [], selected: nil) == nil)
}

@Test func savedKeepsOnlyWebAddresses() throws {
  let urls: [URL?] = [URL(string: "https://github.com/acme"), URL(string: "file:///etc/hosts"),
                      URL(string: "javascript:alert(1)"), nil, URL(string: "http://localhost:5173/login")]
  let saved = try #require(BrowserColumnSaved.make(open: true, width: 480, urls: urls, selected: 4))
  #expect(saved.urls == ["https://github.com/acme", nil, nil, nil, "http://localhost:5173/login"])
  #expect(saved.restoredURLs.map { $0?.absoluteString } == ["https://github.com/acme", nil, nil, nil, "http://localhost:5173/login"])
  #expect(saved.selected == 4)
}

@Test func savedClampsTheSelectionAndTheTabCount() throws {
  let many = (0..<30).map { URL(string: "https://example.com/\($0)") }
  let saved = try #require(BrowserColumnSaved.make(open: false, width: nil, urls: many, selected: 25))
  #expect(saved.urls.count == BrowserColumnSaved.maxTabs)
  #expect(saved.selected == BrowserColumnSaved.maxTabs - 1)
}

@Test func aClosedColumnWithNothingInItIsNotSaved() {
  #expect(BrowserColumnSaved.make(open: false, width: 500, urls: [nil], selected: 0) == nil)
  #expect(BrowserColumnSaved.make(open: true, width: nil, urls: [nil], selected: 0) != nil)
}

@Test func savedRoundTripsThroughJSONAndToleratesJunk() throws {
  let saved = try #require(BrowserColumnSaved.make(open: true, width: 400, urls: [URL(string: "https://a.dev")], selected: 0))
  let back = try JSONDecoder().decode(BrowserColumnSaved.self, from: JSONEncoder().encode(saved))
  #expect(back == saved)
  let junk = #"{"open":true,"urls":["not a url", 7],"selected":-3}"#
  #expect((try? JSONDecoder().decode(BrowserColumnSaved.self, from: Data(junk.utf8))) == nil)
  let odd = #"{"open":true,"urls":["not a url","https://b.dev"],"selected":-3}"#
  let decoded = try JSONDecoder().decode(BrowserColumnSaved.self, from: Data(odd.utf8))
  #expect(decoded.restoredURLs.map { $0?.absoluteString } == [nil, "https://b.dev"])
  #expect(decoded.restoredSelection == 0)
}
