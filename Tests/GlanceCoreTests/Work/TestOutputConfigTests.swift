import Testing
@testable import GlanceCore

@Suite struct TestOutputConfigTests {
  @Test func playwrightOutputDirInSingleQuotes() {
    let config = """
    import { defineConfig } from '@playwright/test';
    export default defineConfig({
      testDir: './e2e',
      outputDir: 'e2e-artifacts',
      use: { baseURL: 'http://localhost:3000' },
    });
    """
    #expect(TestOutputConfig.folders(inConfig: config) == ["e2e-artifacts"])
  }

  @Test func playwrightOutputDirInDoubleQuotesAndBackticks() {
    #expect(TestOutputConfig.folders(inConfig: #"export default { outputDir: "./out/results" }"#) == ["./out/results"])
    #expect(TestOutputConfig.folders(inConfig: "export default { outputDir: `out` }") == ["out"])
    #expect(TestOutputConfig.folders(inConfig: #"module.exports = { "outputDir": "quoted-key" }"#) == ["quoted-key"])
  }

  @Test func cypressNamesBothFolders() {
    let config = """
    const { defineConfig } = require("cypress");
    module.exports = defineConfig({
      e2e: { baseUrl: "http://localhost:3000" },
      videosFolder: "tmp/videos",
      screenshotsFolder: 'tmp/shots',
    });
    """
    #expect(TestOutputConfig.folders(inConfig: config) == ["tmp/videos", "tmp/shots"])
  }

  @Test func commentedOutSettingsAreIgnored() {
    let config = """
    export default defineConfig({
      // outputDir: 'old-results',
      /* videosFolder: 'old-videos',
         screenshotsFolder: 'old-shots' */
      outputDir: 'new-results', // not 'other'
      baseURL: 'http://x.test/a//b',
    });
    """
    #expect(TestOutputConfig.folders(inConfig: config) == ["new-results"])
  }

  @Test func aConfigNamingNothingGivesNothing() {
    #expect(TestOutputConfig.folders(inConfig: "export default defineConfig({ testDir: './e2e' })").isEmpty)
    #expect(TestOutputConfig.folders(inConfig: "").isEmpty)
  }

  @Test func onlyAStringLiteralCountsAndOnlyTheWholeName() {
    #expect(TestOutputConfig.folders(inConfig: "export default { outputDir: path.join(__dirname, 'x') }").isEmpty)
    #expect(TestOutputConfig.folders(inConfig: "export default { outputDir: `${root}/x` }").isEmpty)
    #expect(TestOutputConfig.folders(inConfig: "export default { myoutputDir: 'x', outputDirs: 'y' }").isEmpty)
    #expect(TestOutputConfig.folders(inConfig: "export default { outputDir: '' }").isEmpty)
  }

  @Test func eachFolderOnce() {
    #expect(TestOutputConfig.folders(inConfig: "a({ outputDir: 'o', videosFolder: 'o', screenshotsFolder: 'o' })") == ["o"])
  }

  @Test func aHugeConfigIsReadOnlyInPart() {
    let filler = String(repeating: "// padding\n", count: 20_000)
    #expect(TestOutputConfig.folders(inConfig: filler + "outputDir: 'late'").isEmpty)
    #expect(TestOutputConfig.folders(inConfig: "outputDir: 'early'\n" + filler) == ["early"])
  }
}
