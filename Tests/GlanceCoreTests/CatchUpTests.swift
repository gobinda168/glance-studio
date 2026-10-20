import Foundation
import Testing
@testable import GlanceCore

private func row(_ key: String, _ kind: Notice.Kind = .slackDM) -> NoticeBook.Row {
  NoticeBook.Row(newest: Notice(id: key, source: kind.source, kind: kind, title: "T\(key)", place: "P", preview: "text \(key)",
                                date: Date(timeIntervalSince1970: 0), threadKey: key, target: .none), folded: 0, unread: true)
}

@Test func thePromptListsRowsWithTheirKeys() {
  let p = CatchUp.prompt(rows: [row("a"), row("b", .githubReviewRequested)], now: Date(timeIntervalSince1970: 60))
  #expect(p.contains("[a]") && p.contains("[b]") && p.contains("text a") && p.contains("Review requested"))
  #expect(p.contains("JSON"))
}

@Test func atMostSixtyRows() {
  let rows = (0..<80).map { row("k\($0)") }
  let p = CatchUp.prompt(rows: rows, now: Date())
  #expect(p.contains("[k59]") && !p.contains("[k60]"))
}

@Test func aBriefParses() {
  let b = CatchUp.brief(from: "```json\n{\"summary\":\"3 need you\",\"lines\":[{\"text\":\"Riya wants a review\",\"ids\":[\"a\"]}]}\n```")
  #expect(b?.summary == "3 need you" && b?.lines.first?.ids == ["a"])
  #expect(CatchUp.brief(from: "sorry") == nil)
}

@Test func aBriefGoesStaleAfterThreeNewRows() {
  #expect(!CatchUp.isStale(briefRowKeys: ["a"], current: [row("a"), row("b"), row("c")]))
  #expect(CatchUp.isStale(briefRowKeys: ["a"], current: [row("a"), row("b"), row("c"), row("d")]))
}

// Beyond the brief's four.

@Test func catchUpPromptSkipsReadRowsAndSortsNewestFirst() {
  let old = NoticeBook.Row(newest: Notice(id: "o", source: .slack, kind: .slackDM, title: "Old", place: nil,
                                          preview: "old one", date: Date(timeIntervalSince1970: 0), threadKey: "old",
                                          target: .none), folded: 2, unread: true)
  let new = NoticeBook.Row(newest: Notice(id: "n", source: .github, kind: .githubMention, title: "New", place: "acme/api",
                                          preview: "new one", date: Date(timeIntervalSince1970: 3_600),
                                          threadKey: "new", target: .none), folded: 0, unread: true)
  let read = NoticeBook.Row(newest: Notice(id: "r", source: .slack, kind: .slackDM, title: "Read", place: nil,
                                           preview: "seen", date: Date(timeIntervalSince1970: 100), threadKey: "read",
                                           target: .none), folded: 0, unread: false)
  let p = CatchUp.prompt(rows: [old, read, new], now: Date(timeIntervalSince1970: 7_200))
  #expect(!p.contains("[read]"))
  let newAt = p.range(of: "[new]")!.lowerBound, oldAt = p.range(of: "[old]")!.lowerBound
  #expect(newAt < oldAt)
  #expect(p.contains("[old] Slack · Direct messages · Old · 2h ago — old one (+2 more in thread)"))
  #expect(p.contains("[new] GitHub · Mentions · New · acme/api · 1h ago — new one"))
}

@Test func catchUpBriefDropsEmptyLinesAndNeedsSome() {
  let b = CatchUp.brief(from: #"{"summary":" All quiet ","lines":[{"text":"  ","ids":["a"]},{"text":"CI broke","ids":["x", 3]}]}"#)
  #expect(b == CatchUp.Brief(summary: "All quiet", lines: [CatchUp.Line(text: "CI broke", ids: ["x"])]))
  #expect(CatchUp.brief(from: #"{"summary":"x","lines":[]}"#) == nil)
  #expect(CatchUp.brief(from: #"{"lines":[{"text":"no summary","ids":[]}]}"#)?.summary == "")
}

@Test func catchUpStalenessCountsOnlyUnreadRows() {
  let read = (1...4).map { key -> NoticeBook.Row in
    let r = row("r\(key)")
    return NoticeBook.Row(newest: r.newest, folded: 0, unread: false)
  }
  #expect(!CatchUp.isStale(briefRowKeys: [], current: read))
}
