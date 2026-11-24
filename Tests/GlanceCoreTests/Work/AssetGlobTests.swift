import Testing
@testable import GlanceCore

@Suite struct AssetGlobTests {
  @Test func aFolderWithTwoStars() {
    #expect(AssetGlob.matches("docs/screens/**", path: "docs/screens/login.png"))
    #expect(AssetGlob.matches("docs/screens/**", path: "docs/screens/web/deep/login.png"))
    #expect(!AssetGlob.matches("docs/screens/**", path: "docs/screensaver/login.png"))
    #expect(!AssetGlob.matches("docs/screens/**", path: "other/docs/screens/login.png"))
    #expect(!AssetGlob.matches("docs/screens/**", path: "docs/login.png"))
  }

  @Test func twoStarsInTheMiddleMatchZeroOrMoreFolders() {
    #expect(AssetGlob.matches("apps/**/test-results/*.png", path: "apps/web/test-results/a.png"))
    #expect(AssetGlob.matches("apps/**/test-results/*.png", path: "apps/test-results/a.png"))
    #expect(AssetGlob.matches("apps/**/test-results/*.png", path: "apps/web/admin/test-results/a.png"))
    #expect(!AssetGlob.matches("apps/**/test-results/*.png", path: "apps/web/test-results/sub/a.png"))
  }

  @Test func aPatternWithoutASlashMatchesAtAnyDepth() {
    #expect(AssetGlob.matches("*.png", path: "a.png"))
    #expect(AssetGlob.matches("*.png", path: "docs/shots/a.png"))
    #expect(!AssetGlob.matches("*.png", path: "docs/shots/a.jpg"))
    #expect(!AssetGlob.matches("*.png", path: "docs/a.png/b.txt"))
  }

  @Test func oneStarStaysInsideAFolder() {
    #expect(AssetGlob.matches("docs/*.png", path: "docs/a.png"))
    #expect(!AssetGlob.matches("docs/*.png", path: "docs/sub/a.png"))
    #expect(AssetGlob.matches("shot-*-final.png", path: "shot-12-final.png"))
    #expect(AssetGlob.matches("a?c.png", path: "abc.png"))
    #expect(!AssetGlob.matches("a?c.png", path: "ac.png"))
  }

  @Test func aLiteralPathMatchesItself() {
    #expect(AssetGlob.matches("docs/hero.png", path: "docs/hero.png"))
    #expect(!AssetGlob.matches("docs/hero.png", path: "docs/hero.jpg"))
    #expect(!AssetGlob.matches("docs/hero.png", path: "x/docs/hero.png"))
  }

  @Test func matchingIsCaseSensitive() {
    #expect(!AssetGlob.matches("docs/**", path: "Docs/a.png"))
  }

  @Test func dotDotIsRefusedInThePatternAndThePath() {
    #expect(!AssetGlob.matches("../**", path: "../secrets/a.png"))
    #expect(!AssetGlob.matches("docs/../**", path: "docs/../a.png"))
    #expect(!AssetGlob.matches("**", path: "docs/../../a.png"))
    #expect(!AssetGlob.matches("docs/**", path: "docs/../../etc/a.png"))
  }

  @Test func absoluteAndEmptyInputsAreRefused() {
    #expect(!AssetGlob.matches("/etc/**", path: "/etc/a.png"))
    #expect(!AssetGlob.matches("**", path: "/etc/a.png"))
    #expect(!AssetGlob.matches("", path: "a.png"))
    #expect(!AssetGlob.matches("**", path: ""))
    #expect(!AssetGlob.matches("~/**", path: "~/a.png"))
  }

  @Test func aLongPatternDoesNotBlowUp() {
    let pattern = String(repeating: "*a", count: 40) + "b"
    #expect(!AssetGlob.matches(pattern, path: String(repeating: "a", count: 300)))
  }
}
