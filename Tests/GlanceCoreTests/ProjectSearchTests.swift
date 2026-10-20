import Foundation
import Testing
@testable import GlanceCore

private func find(_ query: String, in text: String, _ options: SearchOptions = SearchOptions(), limit: Int = 100) throws -> [SearchMatch] {
  ProjectSearch.matches(in: text, path: "a.txt", regex: try ProjectSearch.makeRegex(query: query, options: options), limit: limit)
}

@Test func aLiteralSearchIgnoresCaseByDefaultAndTreatsSymbolsLiterally() throws {
  let found = try find("a.b", in: "A.B and axb\nlast a.b")
  #expect(found.map(\.line) == [1, 2])
  #expect(found.map(\.column) == [1, 6])
  #expect(found.allSatisfy { $0.length == 3 })
}

@Test func matchCaseWholeWordAndRegexOptionsApply() throws {
  #expect(try find("foo", in: "Foo foo", SearchOptions(caseSensitive: true)).map(\.column) == [5])
  #expect(try find("foo", in: "foo foobar barfoo foo", SearchOptions(wholeWord: true)).map(\.column) == [1, 19])
  #expect(try find(#"\d+"#, in: "a1 b22 c333", SearchOptions(regex: true)).map(\.length) == [1, 2, 3])
  #expect(try find("a.c", in: "abc a.c", SearchOptions(regex: false)).map(\.column) == [5])
}

@Test func severalMatchesOnOneLineAreAllReported() throws {
  #expect(try find("ab", in: "ababab").map(\.column) == [1, 3, 5])
}

@Test func columnsCountUTF16UnitsLikeMonaco() throws {
  // 🙂 is two UTF-16 units, é is one.
  let found = try find("needle", in: "🙂é needle")
  #expect(found.first?.column == 5)
  #expect(found.first?.length == 6)
}

@Test func crlfLinesAreSplitCleanly() throws {
  let found = try find("b", in: "a\r\nb\r\nb")
  #expect(found.map(\.line) == [2, 3])
  #expect(found.map(\.column) == [1, 1])
}

@Test func theLimitStopsTheScan() throws {
  #expect(try find("a", in: "aaaaaaaaaa", limit: 3).count == 3)
}

@Test func emptyAndInvalidQueriesAreErrors() {
  #expect(throws: SearchError.emptyQuery) { try ProjectSearch.makeRegex(query: "", options: SearchOptions()) }
  #expect(throws: SearchError.self) { try ProjectSearch.makeRegex(query: "(", options: SearchOptions(regex: true)) }
  // The same text is fine as a literal.
  #expect(throws: Never.self) { try ProjectSearch.makeRegex(query: "(", options: SearchOptions(regex: false)) }
}

@Test func zeroLengthMatchesAreNotResults() throws {
  #expect(try find("a*", in: "bbb", SearchOptions(regex: true)).isEmpty)
}

@Test func aPreviewDropsIndentationAndKeepsTheMatchInside() {
  let preview = ProjectSearch.preview(line: "        let value = 42", start: 12, length: 5)
  #expect(preview.text == "let value = 42")
  #expect((preview.text as NSString).substring(with: NSRange(location: preview.start, length: 5)) == "value")
}

@Test func aLongLineIsWindowedAroundTheMatch() {
  let line = String(repeating: "x", count: 500) + "NEEDLE" + String(repeating: "y", count: 500)
  let preview = ProjectSearch.preview(line: line, start: 500, length: 6)
  #expect((preview.text as NSString).length <= 240)
  #expect((preview.text as NSString).substring(with: NSRange(location: preview.start, length: 6)) == "NEEDLE")
}
