import Foundation
import Testing
@testable import GlanceCore

private func tool(_ id: String, _ kind: ToolKind, parent: String? = nil, error: Bool = false) -> TimelineRow {
  TimelineRow(id: id, kind: .tool(name: "X", kind: kind, result: error ? ToolResult(output: "", isError: true, exitCode: nil, images: []) : nil, denied: false), time: nil, parent: parent)
}
private func prose(_ id: String) -> TimelineRow { TimelineRow(id: id, kind: .prose(markdown: "hi"), time: nil, parent: nil) }

@Test func chunkerKeepsPartialLine() {
  var c = LineChunker()
  #expect(c.feed(Data("{\"a\":1}\n{\"b\"".utf8)) == ["{\"a\":1}"])
  #expect(c.feed(Data(":2}\n".utf8)) == ["{\"b\":2}"])
  #expect(c.feed(Data("\n\n".utf8)) == [])
}

@Test func quietRunsGroup() {
  let blocks = TimelineLayout.blocks([prose("p"), tool("r1", .read(path: "a")), tool("r2", .read(path: "b")), tool("s1", .search(pattern: "foo", path: nil)), prose("q")])
  #expect(blocks.map(\.id) == ["p", "g-r1", "q"])
  guard case .group(_, let label, let rows) = blocks[1] else { Issue.record("no group"); return }
  #expect(rows.count == 3)
  #expect(label == "Read 2 files, searched 'foo'")
}

@Test func singleReadLabelNamesTheFile() {
  #expect(TimelineLayout.label([tool("r", .read(path: "src/a.ts"))]) == "Read src/a.ts")
  #expect(TimelineLayout.label([tool("s", .search(pattern: "x", path: nil)), tool("t", .search(pattern: "y", path: nil))]) == "Searched 2 patterns")
}

@Test func failedReadIsNotQuiet() {
  #expect(!TimelineLayout.isQuiet(tool("r", .read(path: "a"), error: true)))
  #expect(!TimelineLayout.isQuiet(tool("b", .bash(command: "ls", summary: nil))))
}

@Test func taskNestsItsChildren() {
  let blocks = TimelineLayout.blocks([tool("t", .task(summary: "Verify")), tool("c1", .read(path: "a"), parent: "t"), tool("c2", .bash(command: "ls", summary: nil), parent: "t")])
  guard case .task(let row, let children) = blocks.first else { Issue.record("no task"); return }
  #expect(row.id == "t")
  #expect(children.map(\.id) == ["g-c1", "c2"])
}

@Test func foldKeepsFirstLines() {
  let out = (1...400).map(String.init).joined(separator: "\n")
  let folded = TimelineLayout.fold(out)
  #expect(folded.shown == (1...8).map(String.init).joined(separator: "\n"))
  #expect(folded.hidden == 392)
  #expect(TimelineLayout.fold("a\nb").hidden == 0)
}

@Test func diffCounts() {
  let c = TimelineLayout.counts([DiffLine(mark: .added, text: "a"), DiffLine(mark: .added, text: "b"), DiffLine(mark: .removed, text: "c"), DiffLine(mark: .context, text: "d")])
  #expect(c.added == 2 && c.removed == 1)
}

@Test func mediaLinksFindsLocalFilesNotURLs() {
  let text = "Saved /tmp/shot.png and ./out/demo.mp4, see https://x.com/a.png and ~/Desktop/b.JPG."
  #expect(MediaLinks.find(in: text, root: "/p", home: "/Users/me") == ["/tmp/shot.png", "/p/out/demo.mp4", "/Users/me/Desktop/b.JPG"])
  #expect(MediaLinks.kind(of: "a.MOV") == .video)
  #expect(MediaLinks.kind(of: "a.txt") == nil)
}

@Test func mediaLinksSkipsRelativeWhenNoRoot() {
  #expect(MediaLinks.find(in: "see ./out/a.png and /tmp/b.png", root: nil, home: "/Users/me") == ["/tmp/b.png"])
}

@Test func failureFoldKeepsErrorLinesAndTheTail() {
  let output = (1...20).map { $0 == 3 ? "✗ test_a" : $0 == 9 ? "Error: boom" : $0 == 18 ? "FAIL suite" : "line \($0)" }.joined(separator: "\n")
  let folded = TimelineLayout.foldFailure(output)
  // 3 and 9 by match, 17...20 as the tail (18 matches and is in the tail too: once).
  #expect(folded.shown.components(separatedBy: "\n") == ["✗ test_a", "Error: boom", "line 17", "FAIL suite", "line 19", "line 20"])
  #expect(folded.hidden == 14)
}

@Test func failureFoldOfShortOutputHidesNothing() {
  let folded = TimelineLayout.foldFailure("a\nb\nc")
  #expect(folded.shown == "a\nb\nc" && folded.hidden == 0)
}

@Test func expandLabelPluralises() {
  #expect(TimelineLayout.expandLabel(total: 9, hidden: 1, failed: false) == "Show 1 more line")
  #expect(TimelineLayout.expandLabel(total: 20, hidden: 12, failed: false) == "Show 12 more lines")
  #expect(TimelineLayout.expandLabel(total: 20, hidden: 14, failed: true) == "Show all 20 lines (14 more)")
  #expect(TimelineLayout.expandLabel(total: 6, hidden: 1, failed: true) == "Show all 6 lines (1 more)")
  #expect(TimelineLayout.expandLabel(total: 5, hidden: 0, failed: true) == nil)
}

// MARK: Clips and explainers in the timeline (Assets, F40)

private let t0 = Date(timeIntervalSince1970: 1_000_000)
private func timed(_ id: String, at seconds: Double, parent: String? = nil) -> TimelineRow {
  TimelineRow(id: id, kind: .prose(markdown: id), time: t0.addingTimeInterval(seconds), parent: parent)
}
private func capture(_ id: String, _ kind: ProofCapture.Kind, at seconds: Double) -> ProofCapture {
  ProofCapture(id: id, kind: kind, file: id + ".mp4", caption: id, at: t0.addingTimeInterval(seconds), source: .glance)
}

@Test func aClipBetweenTwoRowsSitsAfterTheEarlierOne() {
  let rows = [timed("a", at: 10), timed("b", at: 30)]
  let placed = TimelineLayout.mediaRows(captures: [capture("clip", .clip, at: 20)], rows: rows)
  #expect(placed.map(\.capture.id) == ["clip"])
  #expect(placed.map(\.after) == ["a"])
}

@Test func aClipAtARowsExactTimeSitsAfterThatRow() {
  let rows = [timed("a", at: 10), timed("b", at: 30)]
  #expect(TimelineLayout.mediaRows(captures: [capture("clip", .clip, at: 30)], rows: rows).map(\.after) == ["b"])
}

@Test func aClipBeforeTheFirstRowComesFirst() {
  let rows = [timed("a", at: 10), timed("b", at: 30)]
  let placed = TimelineLayout.mediaRows(captures: [capture("clip", .clip, at: 5)], rows: rows)
  #expect(placed.count == 1)
  #expect(placed[0].after == nil)
}

@Test func aClipAfterTheLastRowSitsAfterIt() {
  let rows = [timed("a", at: 10), timed("b", at: 30)]
  #expect(TimelineLayout.mediaRows(captures: [capture("clip", .clip, at: 99)], rows: rows).map(\.after) == ["b"])
}

@Test func onlyClipsAndExplainersArePlacedAndNoneMeansNone() {
  let rows = [timed("a", at: 10)]
  let others = [capture("shot", .screenshot, at: 12), capture("doc", .file, at: 12)]
  #expect(TimelineLayout.mediaRows(captures: others, rows: rows).isEmpty)
  #expect(TimelineLayout.mediaRows(captures: [], rows: rows).isEmpty)
  let both = TimelineLayout.mediaRows(captures: [capture("v", .explainer, at: 12), capture("c", .clip, at: 13)], rows: rows)
  #expect(both.map(\.capture.id) == ["v", "c"])
}

@Test func aSubagentsRowIsNotAPlaceAndRowsWithoutATimeAreSkipped() {
  let rows = [timed("a", at: 10), timed("child", at: 20, parent: "a"),
              TimelineRow(id: "untimed", kind: .prose(markdown: "x"), time: nil, parent: nil), timed("b", at: 40)]
  let placed = TimelineLayout.mediaRows(captures: [capture("clip", .clip, at: 25)], rows: rows)
  #expect(placed.map(\.after) == ["a"])
}

@Test func placedMediaKeepsTheOrderTheyHappenedIn() {
  let rows = [timed("a", at: 10)]
  let placed = TimelineLayout.mediaRows(captures: [capture("late", .clip, at: 30), capture("early", .clip, at: 20)], rows: rows)
  #expect(placed.map(\.capture.id) == ["early", "late"])
}
