import Foundation
import Testing
@testable import GlanceCore

private func entry(_ id: String, _ name: String, tags: [String] = [], description: String = "",
                   inputs: [AutomationInput] = [], readme: String = "") -> AutomationSearchEntry {
  AutomationSearchEntry(manifest: AutomationManifest(id: id, name: name, description: description, tags: tags,
                                                     inputs: inputs),
                        readme: readme)
}

private let library = [
  entry("fix-red-ci", "Fix red CI", tags: ["github", "ci"], description: "Push a fix when a PR's checks fail."),
  entry("pr-digest", "Morning PR digest", tags: ["github", "pr"], description: "Summarize open pull requests.",
        inputs: [AutomationInput(name: "repo", description: "owner/name")]),
  entry("tidy-downloads", "Tidy downloads", description: "File PDFs from Downloads into folders.",
        readme: "Uses ci-style rules for receipts."),
  entry("resume-tailor", "Résumé tailor", tags: ["jobs"], description: "Tailor the résumé to a job post."),
  entry("meeting-memo", "会議メモ", tags: ["meetings"], description: "会議のメモを Slack に投稿"),
]

private func ids(_ query: String, limit: Int = 20) -> [String] {
  AutomationSearch.rank(query, in: library, limit: limit).map(\.id)
}

@Test func nameBeatsTagsBeatsDescriptionBeatsInputsBeatsReadme() {
  // "ci": name + tag (fix-red-ci) > README only (tidy-downloads).
  #expect(ids("ci") == ["fix-red-ci", "tidy-downloads"])
  let byField = [
    entry("a", "Alpha", readme: "digest"),
    entry("b", "Beta", inputs: [AutomationInput(name: "digest")]),
    entry("c", "Gamma", description: "A digest."),
    entry("d", "Delta", tags: ["digest"]),
    entry("e", "Digest"),
  ]
  #expect(AutomationSearch.rank("digest", in: byField).map(\.id) == ["e", "d", "c", "b", "a"])
  #expect(AutomationSearch.rank("digest", in: byField).map(\.score) == [20, 12, 6, 4, 2])
}

@Test func wholeWordsCountDoubleAPrefix() {
  #expect(AutomationSearch.rank("pull", in: library) == [AutomationSearchHit(id: "pr-digest", score: 6)])
  #expect(AutomationSearch.rank("pul", in: library) == [AutomationSearchHit(id: "pr-digest", score: 3)])
  #expect(AutomationSearch.rank("p", in: library).isEmpty)
  #expect(ids("pr") == ["pr-digest", "fix-red-ci"])
}

@Test func everyWordAddsUp() {
  #expect(ids("github digest") == ["pr-digest", "fix-red-ci"])
  #expect(ids("receipts downloads") == ["tidy-downloads"])
  #expect(ids("nothing matches this") == [])
}

@Test func anEmptyQueryListsEverythingByName() {
  #expect(ids("") == ["fix-red-ci", "pr-digest", "resume-tailor", "tidy-downloads", "meeting-memo"])
  #expect(ids("", limit: 2) == ["fix-red-ci", "pr-digest"])
}

@Test func tiesBreakByNameThenID() {
  let twins = [entry("b", "Same", tags: ["x"]), entry("a", "Same", tags: ["x"]), entry("c", "Other", tags: ["x"])]
  #expect(AutomationSearch.rank("x", in: twins).map(\.id) == ["c", "a", "b"])
}

// Review Focus: names in other scripts and with accents are found by what the user types.
@Test func accentsCaseAndOtherScriptsMatch() {
  #expect(ids("RESUME") == ["resume-tailor"])
  #expect(ids("résumé") == ["resume-tailor"])
  #expect(ids("会議") == ["meeting-memo"])
  #expect(ids("slack") == ["meeting-memo"])
  #expect(AutomationSearch.tokens("fix_red-CI, v2.1") == ["fix", "red", "ci", "v2", "1"])
}
