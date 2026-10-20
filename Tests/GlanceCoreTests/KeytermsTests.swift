import Testing
@testable import GlanceCore

@Suite struct KeytermsTests {
  @Test func ranksReplyCodeThenFilesThenBuiltIns() {
    let reply = "Call `useEffect()` in `src/hooks/useSession.ts`, then run `npm run build`. See `ab`."
    let terms = Keyterms.build(reply: reply, projectFiles: ["Sources/Glance/Narrator.swift", "README.md"])
    #expect(Array(terms.prefix(4)) == ["useEffect", "useSession.ts", "Narrator.swift", "README.md"])
    #expect(terms.contains("Claude"))
    #expect(!terms.contains("npm run build"))   // commands are skipped
    #expect(!terms.contains("ab"))              // too short
  }

  @Test func dedupesCaseInsensitively() {
    let terms = Keyterms.build(reply: "`Glance` and `glance`", projectFiles: ["x/Glance"])
    #expect(terms.filter { $0.lowercased() == "glance" }.count == 1)
  }

  @Test func capsAtFiftyAndDropsLongTerms() {
    let files = (0..<80).map { "dir/file\($0).swift" } + [String(repeating: "x", count: 21) + ".swift"]
    let terms = Keyterms.build(reply: nil, projectFiles: files)
    #expect(terms.count == Keyterms.limit)
    #expect(terms.allSatisfy { (3...20).contains($0.count) })
  }

  /// Scribe rejects the whole session when any keyterm is over 20 characters.
  @Test func longFileNamesFallBackToTheirStem() {
    let terms = Keyterms.build(reply: "`SettingsWindowModelTests.swift`",
                               projectFiles: ["Tests/PanelStateTests.swift", "a/AnExtremelyLongTypeName.swift"])
    #expect(terms.first == "PanelStateTests")
    #expect(!terms.contains { $0.hasPrefix("SettingsWindow") || $0.hasPrefix("AnExtremely") })
    #expect(terms.allSatisfy { $0.count <= Keyterms.maxLength })
  }
}
