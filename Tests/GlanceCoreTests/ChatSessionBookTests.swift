import Foundation
import Testing
@testable import GlanceCore

@Test func usingASessionPutsItFirstAndMakesItActive() {
  var book = ChatSessionBook()
  book.use("a")
  book.use("b")
  book.use("a")
  #expect(book.ids == ["a", "b"])
  #expect(book.active == "a")
}

@Test func aBlankChatKeepsTheListAndHasNoActiveSession() {
  var book = ChatSessionBook(ids: ["a", "b"], active: "a")
  book.startBlank()
  #expect(book.ids == ["a", "b"])
  #expect(book.active == nil)
}

@Test func activatingSwitchesToAKnownSessionWithoutReordering() {
  var book = ChatSessionBook(ids: ["a", "b", "c"], active: "a")
  book.activate("c")
  #expect(book.active == "c")
  #expect(book.ids == ["a", "b", "c"])
  book.activate("zzz")
  #expect(book.active == "c")
}

@Test func theListIsCappedAndTheActiveSessionSurvivesIt() {
  var book = ChatSessionBook()
  for n in 0..<(ChatSessionBook.limit + 5) { book.use("s\(n)") }
  #expect(book.ids.count == ChatSessionBook.limit)
  #expect(book.ids.first == "s\(ChatSessionBook.limit + 4)")
  #expect(book.active == book.ids.first)
}

@Test func pruningDropsMissingSessionsButNeverTheActiveOne() {
  var book = ChatSessionBook(ids: ["a", "b", "c"], active: "b")
  book.prune { $0 == "a" || $0 == "b" }
  #expect(book.ids == ["b", "c"])
  #expect(book.active == "b")
}

@Test func storedRoundTripsAndReadsTheOldSingleId() {
  let book = ChatSessionBook(ids: ["a", "b"], active: "b")
  #expect(ChatSessionBook(stored: book.stored) == book)
  #expect(ChatSessionBook(stored: "legacy") == ChatSessionBook(ids: ["legacy"], active: "legacy"))
  #expect(ChatSessionBook(stored: nil) == ChatSessionBook())
  #expect(ChatSessionBook(stored: 42) == ChatSessionBook())
  #expect(ChatSessionBook(stored: ["ids": ["a", 3, "b"], "active": "gone"]) == ChatSessionBook(ids: ["a", "b"], active: nil))
}

@Test func aSessionsTitleIsItsFirstPromptWithoutTheContextLine() {
  let jsonl = [
    #"{"type":"queue-operation"}"#,
    #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
    #"{"type":"user","isMeta":true,"message":{"role":"user","content":"meta"}}"#,
    #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Razor Code: a.ts, line 3 selected] why is   this\nslow?"}]}}"#,
    #"{"type":"user","message":{"role":"user","content":"a second prompt"}}"#,
  ].joined(separator: "\n")
  #expect(ChatTranscript.title(jsonl: jsonl) == "why is this slow?")
  #expect(ChatTranscript.title(jsonl: #"{"type":"queue-operation"}"#) == nil)
  #expect(ChatTranscript.title(jsonl: "") == nil)
}

@Test func aLongTitleIsCut() {
  let long = String(repeating: "word ", count: 60)
  let jsonl = #"{"type":"user","message":{"role":"user","content":"\#(long)"}}"#
  let title = ChatTranscript.title(jsonl: jsonl)
  #expect(title != nil && title!.count <= 100)
}

@Test func theComposerPayloadCarriesTheSessionList() throws {
  let composer = ChatComposer(context: nil, route: .headless, working: false, notice: nil,
                              sessions: [ChatSessionEntry(id: "a", title: "Fix the loop", updated: Date(timeIntervalSince1970: 100))],
                              activeSession: "a")
  let list = try #require(composer.payload["sessions"] as? [[String: Any]])
  #expect(list.count == 1)
  #expect(list[0]["id"] as? String == "a")
  #expect(list[0]["title"] as? String == "Fix the loop")
  #expect(list[0]["updated"] as? Double == 100)
  #expect(composer.payload["active"] as? String == "a")
  let blank = ChatComposer(context: nil, route: .headless, working: false, notice: nil)
  #expect(blank.payload["active"] is NSNull)
  #expect((blank.payload["sessions"] as? [Any])?.isEmpty == true)
}
