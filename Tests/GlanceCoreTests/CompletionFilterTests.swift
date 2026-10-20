import Foundation
import Testing
@testable import GlanceCore

private func make(_ index: Int, _ word: String, group: String = "", ordered: Bool = false, start: Int = 4,
                  hidden: String = "") -> CompletionCandidate {
  CompletionCandidate(fields: ShellWire.fields("\(index)\t\(group)\ttag\t\(word)\t\t\(ordered ? "o" : "")\t\(start)\t\(hidden)")[...])!
}

@Test func queryIsTheTypedTextFromTheCandidatesStart() {
  #expect(CompletionFilter.query(line: "git che", cursor: 7, start: 4, hidden: "") == "che")
  #expect(CompletionFilter.query(line: "ls /usr/sh", cursor: 10, start: 3, hidden: "/usr/") == "sh")
  #expect(CompletionFilter.query(line: "ls /usr/sh", cursor: 10, start: 3, hidden: "/opt/") == "/usr/sh")
  #expect(CompletionFilter.query(line: "git che", cursor: 3, start: 4, hidden: "") == nil)
  #expect(CompletionFilter.query(line: "git", cursor: 9, start: 4, hidden: "") == nil)
  #expect(CompletionFilter.query(line: "échö ä", cursor: 6, start: 5, hidden: "") == "ä")
}

@Test func prefixMatchesComeBeforeFuzzyOnes() {
  let list = [make(1, "check-attr"), make(2, "cherry-pick"), make(3, "checkout"), make(4, "cache-hit-e")]
  let sections = CompletionFilter.sections(list) { _ in "che" }
  let names = sections.flatMap(\.matches).map(\.candidate.name)
  #expect(names == ["check-attr", "checkout", "cherry-pick", "cache-hit-e"])
}

@Test func emptyQueryKeepsEverythingInZshsGroupOrder() {
  let list = [make(1, "zeta", group: "b"), make(2, "alpha", group: "b"), make(3, "mid", group: "a", ordered: true),
              make(4, "first", group: "a", ordered: true)]
  let sections = CompletionFilter.sections(list) { _ in "" }
  #expect(sections.map(\.title) == ["b", "a"])
  #expect(sections[0].matches.map(\.candidate.name) == ["alpha", "zeta"])
  #expect(sections[1].matches.map(\.candidate.name) == ["mid", "first"])
}

@Test func noMatchMeansNoSections() {
  #expect(CompletionFilter.sections([make(1, "checkout")]) { _ in "xyz" }.isEmpty)
  #expect(CompletionFilter.sections([make(1, "checkout")]) { _ in nil }.isEmpty)
}

@Test func matchingIgnoresCase() {
  let names = CompletionFilter.sections([make(1, "README.md"), make(2, "readme.txt")]) { _ in "read" }
    .flatMap(\.matches).map(\.candidate.name)
  #expect(Set(names) == ["README.md", "readme.txt"])
}

@Test func highlightsPrefixAndFuzzyCharacters() throws {
  let prefix = try #require(CompletionFilter.sections([make(1, "checkout")]) { _ in "che" }.first?.matches.first)
  #expect(prefix.highlight == [0..<3])
  let fuzzy = try #require(CompletionFilter.sections([make(1, "checkout")]) { _ in "cko" }.first?.matches.first)
  #expect(fuzzy.highlight == [0..<1, 4..<6])
}
