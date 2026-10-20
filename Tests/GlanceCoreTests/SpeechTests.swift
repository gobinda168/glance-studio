import Testing
@testable import GlanceCore

private func say(_ kind: Block.Kind, _ md: String) -> String? {
  Speech.text(for: Block(kind: kind, markdown: md))
}

@Test func stripsInlineMarkdown() {
  #expect(say(.paragraph, "Okay, **login** is a _three-hop_ ~~dance~~ *flow*.") == "Okay, login is a three-hop dance flow.")
  #expect(say(.paragraph, "See [the docs](https://x.dev/a) or https://example.com/path now.") == "See the docs or now.")
  #expect(say(.paragraph, "An image ![diagram](a.png) here.") == "An image here.")
  #expect(say(.paragraph, "Keep snake_case_names intact.") == "Keep snake_case_names intact.")
}

@Test func shortensInlineCode() {
  #expect(say(.paragraph, "Open `src/auth/session.ts` and call `refresh()`.") == "Open session.ts and call refresh.")
  #expect(say(.paragraph, "Run `git rebase --onto main feature-branch-with-long-name`.") == "Run that command.")
  #expect(say(.paragraph, "Set `retries` to 3.") == "Set retries to 3.")
}

@Test func readsArrowsAsWords() {
  #expect(say(.paragraph, "User → API -> DB") == "User to API to DB")
}

@Test func headingsAndListsBecomeSentences() {
  #expect(say(.heading, "## How it works") == "How it works.")
  #expect(say(.list, "- first thing\n- second thing!\n  more detail\n1. third") == "First thing. Second thing! more detail. Third.")
  #expect(say(.quote, "> quoted line\n> second") == "quoted line second")
}

@Test func silentBlocks() {
  #expect(say(.code, "let a = 1") == nil)
  #expect(say(.mermaid, "graph TD") == nil)
  #expect(say(.table, "| a |") == nil)
  #expect(say(.rule, "---") == nil)
  #expect(say(.paragraph, "`x/y.ts`  ") == "y.ts")
  #expect(say(.paragraph, "   ") == nil)
}
