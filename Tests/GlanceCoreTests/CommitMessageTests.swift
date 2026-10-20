import Testing
@testable import GlanceCore

@Test func theDraftPromptCarriesTheRecentCommitsAndTheDiff() {
  let prompt = CommitMessage.prompt(diff: "+added line", recent: ["feat(x): one", "fix: two"], staged: true)
  #expect(prompt.contains("- feat(x): one\n- fix: two"))
  #expect(prompt.contains("+added line"))
  #expect(prompt.contains("staged"))
  let cut = CommitMessage.prompt(diff: String(repeating: "a", count: 50), recent: [], staged: false, limit: 20)
  #expect(cut.contains(String(repeating: "a", count: 20)) && !cut.contains(String(repeating: "a", count: 21)))
  #expect(cut.contains("30 more characters"))
  #expect(cut.contains("(none)"))
}

@Test func cleaningADraftDropsFencesAndBlankEdges() {
  #expect(CommitMessage.clean("```\nfeat: x\n\nbody\n```\n") == "feat: x\n\nbody")
  #expect(CommitMessage.clean("```text\nfix: y\n```") == "fix: y")
  #expect(CommitMessage.clean("  chore: z  \n") == "chore: z")
}
