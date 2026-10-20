import Foundation
import Testing
@testable import GlanceCore

@Test func aPRDraftPromptHasTheCommitsTheTemplateAndTheDiff() {
  let prompt = PullRequestClaude.prDraftPrompt(branch: "feat/release", base: "main", repository: "o/r",
                                               commits: ["81380ed feat(release): build", "80e4ef5 chore: x"],
                                               diff: "diff --git a/a b/a\n+x\n", template: "## Why\n\n## Testing\n")
  #expect(prompt.hasPrefix("Draft the pull request for feat/release → main in o/r.\n\nCommits (newest first):\n"
    + "- 81380ed feat(release): build\n- 80e4ef5 chore: x"))
  #expect(prompt.contains("The repository's pull request template:\n## Why\n\n## Testing"))
  #expect(prompt.hasSuffix("Diff:\ndiff --git a/a b/a\n+x\n"))
  let long = PullRequestClaude.prDraftPrompt(branch: "b", base: "main", repository: "o/r", commits: [],
                                             diff: String(repeating: "x", count: 30), template: nil, limit: 10)
  #expect(long.contains("Commits (newest first):\n(none)"))
  #expect(long.hasSuffix("Diff:\nxxxxxxxxxx\n[The diff goes on for 20 more characters: read the files for the rest.]"))
  #expect(!long.contains("template"))
}

@Test func claudesDraftSplitsIntoTitleAndDescription() {
  let draft = PullRequestClaude.prDraft("Here it is.\nTITLE: Release: build, sign and publish\n\n## What\n- `release.sh`\n")
  #expect(draft.title == "Release: build, sign and publish")
  #expect(draft.body == "## What\n- `release.sh`")
  let bare = PullRequestClaude.prDraft("## What\n- a\n")
  #expect(bare.title == "" && bare.body == "## What\n- a")
  #expect(PullRequestClaude.prDraft("title: \"Quoted\"\n\nBody").title == "Quoted")
}

@Test func aPRDraftReadsTheTemplateAndSaysWhatItDrewOn() {
  #expect(PullRequestClaude.template { $0 == ".github/PULL_REQUEST_TEMPLATE.md" ? "## Why" : nil } == "## Why")
  #expect(PullRequestClaude.template { _ in nil } == nil)
  #expect(PullRequestClaude.prDraftArguments().last == PullRequestClaude.prDraftRules)
  #expect(PullRequestClaude.prDraftArguments().starts(with: ["-p", "--output-format", "json"]))
  #expect(PullRequestClaude.prDraftRules.contains("TITLE: "))
  #expect(PullRequestClaude.draftNote(commits: 6)
    == "Drafted by Claude from 6 commits and the diff. Edit anything; Claude won't overwrite your changes.")
  #expect(PullRequestClaude.draftNote(commits: 1).hasPrefix("Drafted by Claude from 1 commit and the diff."))
}
