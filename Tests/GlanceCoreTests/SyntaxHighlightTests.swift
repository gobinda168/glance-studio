import Foundation
import Testing
@testable import GlanceCore

private typealias S = SyntaxHighlight.Segment

@Suite struct SyntaxHighlightTests {
  @Test func everyLanguageCompilesAndKeepsTheText() {
    let line = #"  if x == "a // b" { call(Foo, 0x1F) } # note /* c */ 'q' `t`"#
    for language in SyntaxHighlight.Language.allCases {
      let joined = SyntaxHighlight.segments(line, language: language).map(\.text).joined()
      #expect(joined == line, "\(language)")
    }
  }

  @Test func languageByPath() {
    #expect(SyntaxHighlight.Language(path: "backend/views/case.py") == .python)
    #expect(SyntaxHighlight.Language(path: "src/App.TSX") == .javascript)
    #expect(SyntaxHighlight.Language(path: "Dockerfile") == .shell)
    #expect(SyntaxHighlight.Language(path: "notes.txt") == nil)
    #expect(SyntaxHighlight.Language(path: ".gitignore") == nil)
  }

  @Test func python() {
    let segments = SyntaxHighlight.segments(
      #"    if share and q_args.get("share_with_partner") is True:  # yes"#, language: .python)
    #expect(segments == [
      S("    "), S("if", .keyword), S(" share "), S("and", .keyword), S(" q_args."), S("get", .function), S("("),
      S(#""share_with_partner""#, .string), S(") "), S("is", .keyword), S(" "), S("True", .keyword), S(":  "),
      S("# yes", .comment),
    ])
    #expect(SyntaxHighlight.segments("for attempt in range(1, F1_CASE_ATTEMPTS + 1):", language: .python).contains(
      S("F1_CASE_ATTEMPTS", .number)))
    #expect(SyntaxHighlight.segments("@app.route", language: .python) == [S("@app.route", .attribute)])
    #expect(SyntaxHighlight.segments(#"x = f"{a}" + 'b'"#, language: .python).filter { $0.kind == .string }
      .map(\.text) == [#"f"{a}""#, "'b'"])
  }

  @Test func keywordsInsideStringsAndCommentsStayThere() {
    #expect(SyntaxHighlight.segments(#"let s = "if return" // let"#, language: .swift) == [
      S("let", .keyword), S(" s = "), S(#""if return""#, .string), S(" "), S("// let", .comment),
    ])
    #expect(SyntaxHighlight.segments("   * a doc line", language: .javascript) == [S("   * a doc line", .comment)])
  }

  @Test func typesAndUnterminatedStrings() {
    #expect(SyntaxHighlight.segments("const x: Foo = new Bar()", language: .javascript) == [
      S("const", .keyword), S(" x: "), S("Foo", .type), S(" = "), S("new", .keyword), S(" "), S("Bar", .function),
      S("()"),
    ])
    #expect(SyntaxHighlight.segments(#"msg = "open"#, language: .python) == [S("msg = "), S(#""open"#, .string)])
  }

  @Test func dataFormats() {
    #expect(SyntaxHighlight.segments(#"  "name": "glance", "n": 2"#, language: .json) == [
      S("  "), S(#""name""#, .property), S(": "), S(#""glance""#, .string), S(", "), S(#""n""#, .property), S(": "),
      S("2", .number),
    ])
    #expect(SyntaxHighlight.segments("  runs-on: ubuntu-latest # ci", language: .yaml) == [
      S("  runs-on", .property), S(": ubuntu-latest "), S("# ci", .comment),
    ])
    #expect(SyntaxHighlight.segments(#"echo "$HOME" # x"#, language: .shell) == [
      S("echo", .keyword), S(" "), S(#""$HOME""#, .string), S(" "), S("# x", .comment),
    ])
  }
}
