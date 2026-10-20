import Foundation
import Testing
@testable import GlanceCore

private func comment(_ author: String, _ body: String) -> ReviewThreads.Comment {
  .init(id: "c-\(author)", databaseID: 7, author: author, isBot: false, body: body, createdAt: nil,
        reviewState: .commented)
}

private let question = ReviewThreads.Thread(
  id: "T1", isResolved: false, isOutdated: false, path: "Sources/Glance/UpdateService.swift", line: 42, startLine: nil,
  side: .right, resolvedBy: nil,
  comments: [comment("gobinda168", "Badge?"), comment("devon", "Can the badge clear when\r\nthe window is dismissed?")])

@Test func aDraftPromptHasTheThreadTheCodeAndWhoSaidWhat() {
  let prompt = PullRequestClaude.draftPrompt(question, number: 50, title: "Sparkle updates", repository: "o/r",
                                             viewer: "gobinda168",
                                             hunk: "@@ -40,3 +40,4 @@\n badge.show()\n+dismiss()\n")
  #expect(prompt.hasPrefix("Draft gobinda168's reply to this review thread on pull request #50 in o/r, "
    + "\"Sparkle updates\". It's on Sources/Glance/UpdateService.swift, line 42."))
  #expect(prompt.contains("The code it was written on:\n```diff\n@@ -40,3 +40,4 @@\n badge.show()\n+dismiss()\n```"))
  #expect(prompt.hasSuffix("""
    gobinda168 wrote:
       Badge?

    devon wrote:
       Can the badge clear when
       the window is dismissed?
    """))
  // Without a hunk, the prompt goes straight to the comments.
  #expect(!PullRequestClaude.draftPrompt(question, number: 50, title: "T", repository: "o/r", viewer: "g", hunk: " \n")
    .contains("The code it was written on"))
}

@Test func writeWithClaudeWritesTheReplyFromTheUsersNotes() {
  let prompt = PullRequestClaude.draftPrompt(question, number: 50, title: "T", repository: "o/r", viewer: "gobinda168",
                                             hunk: nil, notes: "  yes, on dismiss\r\nI'll add a test \n")
  #expect(prompt.hasSuffix("""
       the window is dismissed?

    gobinda168's notes for the reply. Write the reply from them: keep what they say and decide, in their words \
    where you can, and add only what makes it clear:
       yes, on dismiss
       I'll add a test
    """))
  // Blank notes are no notes.
  #expect(!PullRequestClaude.draftPrompt(question, number: 50, title: "T", repository: "o/r", viewer: "g", hunk: nil,
                                         notes: " \n").contains("notes for the reply"))
}

@Test func aDraftIsReadOnlyClaudeWithItsOwnRules() {
  let arguments = PullRequestClaude.draftArguments()
  #expect(arguments.starts(with: ["-p", "--output-format", "json", "--no-session-persistence",
                                  "--tools", "Read", "Grep", "Glob"]))
  #expect(arguments.contains("--strict-mcp-config"))
  #expect(arguments.last == PullRequestClaude.draftRules)
  #expect(PullRequestClaude.draftRules.contains("change nothing"))
  #expect(PullRequestClaude.hunkArguments(repository: "o/r", commentID: 4106126529)
    == ["api", "repos/o/r/pulls/comments/4106126529", "--jq", ".diff_hunk"])
}

@Test func replyAndFixTellsClaudeTheAnswer() {
  let answered = ReviewInbox.replied(question, by: "gobinda168", body: "Yes: dismissing clears it.")
  #expect(answered.comments.map(\.author) == ["gobinda168", "devon", "gobinda168"])
  #expect(answered.comments.last?.body == "Yes: dismissing clears it.")
  #expect(answered.id == "T1" && answered.path == question.path && answered.line == 42)
}
