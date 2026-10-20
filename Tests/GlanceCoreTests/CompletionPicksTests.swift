import Foundation
import Testing
@testable import GlanceCore

@Test func aPickPlaceIsTheCommandAndItsSubcommands() {
  #expect(CompletionPicks.context(line: "git ch", start: 4) == "git")
  #expect(CompletionPicks.context(line: "git checkout ma", start: 13) == "git checkout")
  #expect(CompletionPicks.context(line: "ls -la /usr/s", start: 7) == "ls")
  #expect(CompletionPicks.context(line: "docker compose -f x.yml up web", start: 27) == "docker compose")
  #expect(CompletionPicks.context(line: "gi", start: 0) == "")
}

@Test func picksOrderAGroupAfterPrefixMatches() {
  let rows = ["1\tg\ttag\tcheck-attr\t\t\t4\t", "2\tg\ttag\tcheckout\t\t\t4\t", "3\tg\ttag\tcherry\t\t\t4\t"]
  let list = rows.compactMap { CompletionCandidate(fields: ShellWire.fields($0)[...]) }
  let boosted = CompletionFilter.sections(list, query: { _ in "che" }, boost: { $0.word == "checkout" ? 5 : 0 })
  #expect(boosted.flatMap(\.matches).map(\.candidate.name) == ["checkout", "check-attr", "cherry"])
}

@Test func storeKeepsPicks() throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("picks-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: folder) }
  let store = try CommandHistoryStore(url: folder.appendingPathComponent("history.sqlite"))
  try store.recordPick(context: "git", candidate: "checkout")
  try store.recordPick(context: "git", candidate: "checkout")
  try store.recordPick(context: "git checkout", candidate: "main")
  #expect(try store.picks() == ["git": ["checkout": 2], "git checkout": ["main": 1]])
}
