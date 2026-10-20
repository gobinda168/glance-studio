import Foundation
import Testing
@testable import GlanceCore

private let home = "/Users/me"
private let app = "/Users/me/Code/app"
private let other = "/Users/me/Code/other"

@Test func turnsInTheFocusedFolderThinkThenNarrate() {
  var router = SessionRouter(home: home)
  _ = router.focus(pwd: app)
  #expect(router.turn(.prompt, cwd: app, file: "/t/1.jsonl") == .thinking(cwd: app))
  #expect(router.turn(.done, cwd: app, file: "/t/1.jsonl") == .show(file: "/t/1.jsonl", cwd: app, narrate: true))
}

@Test func repliesElsewhereAreKeptQuietly() {
  var router = SessionRouter(home: home)
  _ = router.focus(pwd: app)
  #expect(router.turn(.prompt, cwd: other, file: "/t/2.jsonl") == .none)
  #expect(router.turn(.done, cwd: other, file: "/t/2.jsonl") == .none)
}

@Test func focusShowsTheStoredReplyWithoutNarrating() {
  var router = SessionRouter(home: home)
  _ = router.focus(pwd: app)
  _ = router.turn(.done, cwd: other, file: "/t/2.jsonl")
  #expect(router.focus(pwd: other + "/") == .show(file: "/t/2.jsonl", cwd: other, narrate: false))
}

@Test func focusOnAFolderWithoutRepliesClears() {
  var router = SessionRouter(home: home)
  _ = router.focus(pwd: app)
  _ = router.turn(.done, cwd: app, file: "/t/1.jsonl")
  #expect(router.focus(pwd: other) == .clear)
  #expect(router.focus(pwd: nil) == .clear)
}

@Test func refocusingTheSameFolderDoesNothing() {
  var router = SessionRouter(home: home)
  #expect(router.focus(pwd: app) == .clear)
  #expect(router.focus(pwd: "~/Code/app") == .none)
  #expect(router.focusedPwd == app)
}

@Test func theLatestReplyPerFolderWins() {
  var router = SessionRouter(home: home)
  _ = router.focus(pwd: app)
  _ = router.turn(.done, cwd: other, file: "/t/old.jsonl")
  _ = router.turn(.done, cwd: other, file: "/t/new.jsonl")
  #expect(router.focus(pwd: other) == .show(file: "/t/new.jsonl", cwd: other, narrate: false))
}

@Test func turnsWithoutAFolderAreIgnored() {
  var router = SessionRouter(home: home)
  _ = router.focus(pwd: app)
  #expect(router.turn(.done, cwd: nil, file: "/t/x.jsonl") == .none)
}

// MARK: Terminals linked to their sessions (spec 2026-10-11-humanize-summaries-design.md, "Session isolation")

private let a = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!
private let b = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000000")!
private func link(_ surface: UUID, _ file: String, cwd: String = app) -> SessionLink {
  SessionLink(surface: surface, sessionID: file, transcriptPath: file, cwd: cwd, source: "startup")
}

@Test func twoTerminalsInOneFolderNeverMix() {
  var router = SessionRouter(home: home)
  _ = router.setLinks([a: link(a, "/t/a.jsonl"), b: link(b, "/t/b.jsonl")])
  _ = router.focus(.terminal(surface: a, pwd: app))
  #expect(router.turn(.prompt, cwd: app, file: "/t/b.jsonl") == .none)
  #expect(router.turn(.done, cwd: app, file: "/t/b.jsonl") == .none)
  #expect(router.turn(.done, cwd: app, file: "/t/a.jsonl") == .show(file: "/t/a.jsonl", cwd: app, narrate: true))
  #expect(router.focus(.terminal(surface: b, pwd: app)) == .show(file: "/t/b.jsonl", cwd: app, narrate: false))
}

@Test func anUnlinkedTerminalFallsBackToItsFolderButNotToALinkedSession() {
  var router = SessionRouter(home: home)
  _ = router.setLinks([a: link(a, "/t/a.jsonl")])
  _ = router.focus(.terminal(surface: b, pwd: app))
  #expect(router.turn(.done, cwd: app, file: "/t/a.jsonl") == .none)
  #expect(router.turn(.done, cwd: app, file: "/t/old.jsonl") == .show(file: "/t/old.jsonl", cwd: app, narrate: true))
}

@Test func aLinkedTerminalWithNoFinishedTurnClears() {
  var router = SessionRouter(home: home)
  _ = router.setLinks([a: link(a, "/t/a.jsonl")])
  _ = router.focus(.terminal(surface: b, pwd: app))
  _ = router.turn(.done, cwd: app, file: "/t/old.jsonl")
  #expect(router.focus(.terminal(surface: a, pwd: app)) == .clear)
}

@Test func clearMovesTheTerminalToItsNewSession() {
  var router = SessionRouter(home: home)
  _ = router.setLinks([a: link(a, "/t/a.jsonl")])
  _ = router.focus(.terminal(surface: a, pwd: app))
  _ = router.turn(.done, cwd: app, file: "/t/a.jsonl")
  #expect(router.setLinks([a: link(a, "/t/a2.jsonl")]) == .clear)
  #expect(router.turn(.done, cwd: app, file: "/t/a2.jsonl") == .show(file: "/t/a2.jsonl", cwd: app, narrate: true))
  #expect(router.setLinks([a: link(a, "/t/a2.jsonl")]) == .none) // unchanged links do nothing
}

@Test func editorsDontFollowTerminals() {
  var router = SessionRouter(home: home)
  _ = router.turn(.done, cwd: app, file: "/t/1.jsonl")
  #expect(router.focus(.editor(root: app)) == .clear)
  #expect(router.focusedPwd == app)
  #expect(router.turn(.prompt, cwd: app, file: "/t/1.jsonl") == .none)
  #expect(router.turn(.done, cwd: app, file: "/t/1.jsonl") == .none)
}

@Test func linksAnswerBothWays() {
  var router = SessionRouter(home: home)
  _ = router.setLinks([a: link(a, "/t/a.jsonl")])
  #expect(router.link(for: a)?.transcriptPath == "/t/a.jsonl")
  #expect(router.surface(forTranscript: "/t/a.jsonl") == a)
  #expect(router.surface(forTranscript: "/t/x.jsonl") == nil)
}
