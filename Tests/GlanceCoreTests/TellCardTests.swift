import Testing
@testable import GlanceCore

@Suite struct TellCardTests {
  @Test func autoFitsTheContentBetweenTheLimits() {
    #expect(TellCard.height(content: 80, size: .auto) == 120)
    #expect(TellCard.height(content: 300, size: .auto) == 300)
    #expect(TellCard.height(content: 900, size: .auto) == 600)
  }

  @Test func shortCapsAndFullOpensFull() {
    #expect(TellCard.height(content: 900, size: .short) == 260)
    #expect(TellCard.height(content: 80, size: .short) == 120)
    #expect(TellCard.height(content: 80, size: .full) == 600)
  }

  @Test func onlyShortCardsFoldBack() {
    #expect(TellCard.folds(height: 260))
    #expect(TellCard.folds(height: 120))
    #expect(!TellCard.folds(height: 261))
    #expect(TellCard.foldDelay == 10)
  }

  @Test func headlineIsTheFirstLineWithoutMarks() {
    #expect(TellCard.headline("## **CI** passed on `main`\n\nAll 412 tests green.") == "CI passed on main")
    #expect(TellCard.headline("\n\n- [Build 52](https://ci.example/52) is _done_") == "Build 52 is done")
    #expect(TellCard.headline("```swift\nlet x = 1\n```\nDone.") == "Done.")
    #expect(TellCard.headline("| Job | Result |\n|---|---|") == "Job Result")
    #expect(TellCard.headline("> 1. snake_case stays") == "snake_case stays")
    #expect(TellCard.headline(String(repeating: "word ", count: 40)).count == 80)
    #expect(TellCard.headline(String(repeating: "word ", count: 40)).hasSuffix("…"))
    #expect(TellCard.headline("   ") == "Glance has something to tell you")
  }
}
