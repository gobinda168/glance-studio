import Foundation
import Testing
@testable import GlanceCore

private func comment(_ author: String, _ body: String) -> ReviewThreads.Comment {
  .init(id: author, databaseID: 1, author: author, isBot: false, body: body, createdAt: nil, reviewState: .commented)
}

@Test func aFixPromptListsTheThreadsAndForbidsCommits() {
  let one = ReviewThreads.Thread(
    id: "t1", isResolved: false, isOutdated: false, path: "scripts/release.sh", line: 123, startLine: nil, side: .right,
    resolvedBy: nil, comments: [comment("claude", "🔴 Roll the release back.\r\nUse gh release delete."),
                                comment("gobinda168", "Rolling back is simpler.")])
  let range = ReviewThreads.Thread(
    id: "t2", isResolved: false, isOutdated: false, path: "docs/testing.md", line: 14, startLine: 12, side: .right,
    resolvedBy: nil, comments: [comment("devon", "Nit: say macOS asks once.")])
  let file = ReviewThreads.Thread(
    id: "t3", isResolved: false, isOutdated: false, path: "README.md", line: nil, startLine: nil, side: .right,
    resolvedBy: nil, comments: [comment("mira-k", "Split this file.")], isFileLevel: true)
  let prompt = PullRequestClaude.fixPrompt([one, range, file], number: 51, title: "Release: build",
                                           repository: "gobinda168/glance")
  #expect(prompt.hasPrefix(
    "Fix these 3 review comments on pull request #51 in gobinda168/glance, \"Release: build\", in this working tree."))
  #expect(prompt.contains("""
    1. scripts/release.sh, line 123, from claude:
       🔴 Roll the release back.
       Use gh release delete.
       gobinda168 replied:
       Rolling back is simpler.
    """))
  #expect(prompt.contains("2. docs/testing.md, lines 12–14, from devon:\n   Nit: say macOS asks once."))
  #expect(prompt.contains("3. README.md (the whole file), from mira-k:\n   Split this file."))
  #expect(prompt.contains("Don't commit, push, reply on GitHub or resolve anything"))
  #expect(prompt.hasSuffix("If a comment needs no change, say so and leave the files alone."))
  #expect(PullRequestClaude.fixPrompt([one], number: 51, title: "T", repository: "o/r")
    .hasPrefix("Fix this review comment on pull request #51 in o/r, \"T\", in this working tree."))
}
