import Foundation
import Testing
@testable import GlanceCore

private let day = JournalDay(key: "2026-10-09")!
private let now = Date(timeIntervalSince1970: 1_760_000_000)
private let digest = JournalDigest(text: "digest", refs: ["e1": "git:abc", "e2": "claude:s1:2026-10-09"],
                                   projects: ["glance": "/code/glance"])

private func ids() -> () -> String {
  var next = 0
  return { next += 1; return "id\(next)" }
}

private let good = """
  {"headline": "Shipped the journal store",
   "recap_md": "I built the store.\\n\\nThen the digest.",
   "minutes_by_project": {"glance": 120, "elsewhere": 2000},
   "entries": [
     {"title": "Journal store", "summary": "SQLite store with upserts.", "project": "glance", "kind": "SHIPPED",
      "impact": "", "challenge": "Concurrent writers", "approach": "One serial queue", "outcome": "Tests pass",
      "lesson": "WAL helps", "skills": ["Backend", "backend", "testing", "a", "b", "c", "d", "e", "f"],
      "minutes": 95, "public_draft": "Built a local store.", "event_refs": ["e1", "[e2]", "e9"]},
     {"title": "", "summary": "no title, dropped"},
     {"title": "Odd kind", "kind": "celebrated", "minutes": -5}
   ]}
  """

@Test func aGoodReplyBecomesADraft() throws {
  let draft = try JournalRecap.parse(good, day: day, digest: digest, now: now, makeID: ids()).get()
  #expect(draft.headline == "Shipped the journal store")
  #expect(draft.recap == "I built the store.\n\nThen the digest.")
  #expect(draft.minutesByProject == ["/code/glance": 120, "elsewhere": 960])
  #expect(draft.entries.count == 2)
  let entry = draft.entries[0]
  #expect(entry.id == "id1" && entry.position == 0 && entry.day == day)
  #expect(entry.kind == .shipped)
  #expect(entry.project == "/code/glance")
  #expect(entry.skills == ["backend", "testing", "a", "b", "c", "d", "e", "f"])
  #expect(entry.minutes == 95)
  #expect(entry.eventIDs == ["git:abc", "claude:s1:2026-10-09"])
  #expect(entry.challenge == "Concurrent writers" && entry.lesson == "WAL helps")
  #expect(entry.publicDraft == "Built a local store.")
  #expect(!entry.edited && entry.createdAt == now)
  #expect(draft.entries[1].kind == .other && draft.entries[1].minutes == 0 && draft.entries[1].position == 1)
}

@Test func aFencedOrChattyReplyIsStillRead() throws {
  let fenced = "Here you go:\n```json\n{\"headline\": \"H\", \"recap_md\": \"R\", \"entries\": []}\n```\nEnjoy."
  #expect(try JournalRecap.parse(fenced, day: day, digest: digest, now: now).get().headline == "H")
  let chatty = "Sure! {\"headline\": \"H2\", \"recap_md\": \"R\"} hope that helps"
  #expect(try JournalRecap.parse(chatty, day: day, digest: digest, now: now).get().headline == "H2")
}

@Test func aReplyWithoutJSONOrARecapFails() {
  #expect(JournalRecap.parse("I couldn't do it.", day: day, digest: digest, now: now)
    == .failure(JournalRecap.Failure(message: "Claude's reply wasn't JSON.")))
  #expect(JournalRecap.parse(#"{"headline": "", "recap_md": "R"}"#, day: day, digest: digest, now: now)
    == .failure(JournalRecap.Failure(message: "Claude's reply had no recap.")))
}

@Test func fieldsAreCappedAndAtMostEightEntriesKept() throws {
  let many = (0..<12).map { #"{"title": "T\#($0)"}"# }.joined(separator: ",")
  let reply = #"{"headline": "\#(String(repeating: "h", count: 200))", "recap_md": "R", "entries": [\#(many)]}"#
  let draft = try JournalRecap.parse(reply, day: day, digest: digest, now: now).get()
  #expect(draft.headline.count == 90)
  #expect(draft.entries.count == 8)
}

@Test func aRedraftKeepsEditedEntries() {
  let mine = JournalEntry(id: "mine", day: day, position: 2, title: "Mine", edited: true, createdAt: now)
  let stale = JournalEntry(id: "stale", day: day, position: 0, title: "Stale", createdAt: now)
  let fresh = [JournalEntry(id: "new1", day: day, position: 0, title: "New", createdAt: now),
               JournalEntry(id: "new2", day: day, position: 1, title: "New 2", createdAt: now)]
  let merged = JournalRecap.merge(existing: [stale, mine], draft: fresh)
  #expect(merged.map(\.id) == ["mine", "new1", "new2"])
  #expect(merged.map(\.position) == [0, 1, 2])
}

@Test func claudeRunsWithNoToolsNoHooksAndTheJournalRules() {
  let arguments = JournalRecap.arguments()
  #expect(arguments.prefix(4) == ["-p", "--output-format", "json", "--no-session-persistence"])
  #expect(arguments.contains("--strict-mcp-config"))
  let tools = arguments.firstIndex(of: "--tools")!
  #expect(arguments[tools + 1] == "")
  #expect(arguments.last == JournalRecap.systemPrompt)
  #expect(JournalRecap.systemPrompt.contains("public_draft"))
  #expect(JournalRecap.systemPrompt.contains("Never invent numbers"))
  #expect(JournalRecap.prompt(digest).hasPrefix("digest"))
}
