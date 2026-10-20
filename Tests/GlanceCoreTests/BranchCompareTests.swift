import Foundation
import Testing
@testable import GlanceCore

@Test func gitIsAskedAboutTheBranchAgainstGitHubsBase() {
  #expect(BranchCompare.countArguments(base: "main", head: "feat/release")
    == ["rev-list", "--left-right", "--count", "origin/main...feat/release"])
  #expect(BranchCompare.logArguments(base: "main", head: "feat") == ["log", "--format=%h%x1f%s", "origin/main..feat"])
  #expect(BranchCompare.numstatArguments(base: "main", head: "feat")
    == ["diff", "--numstat", "--no-renames", "-z", "origin/main...feat"])
  #expect(BranchCompare.diffArguments(base: "main", head: "feat").suffix(3)
    == ["--src-prefix=a/", "--dst-prefix=b/", "origin/main...feat"])
  #expect(BranchCompare.mergeTreeArguments(base: "main", head: "feat")
    == ["merge-tree", "--write-tree", "--name-only", "--no-messages", "origin/main", "feat"])
  #expect(BranchCompare.upstreamArguments(branch: "feat")
    == ["rev-list", "--left-right", "--count", "origin/feat...feat"])
  #expect(BranchCompare.pushArguments(branch: "feat") == ["push", "--set-upstream", "origin", "feat"])
  #expect(BranchCompare.fetchArguments(base: "main") == ["fetch", "--quiet", "origin", "main"])
  #expect(BranchCompare.headArguments(branch: "feat") == ["rev-parse", "feat"])
}

@Test func branchesComeLocalOrFromGitHub() {
  #expect(BranchCompare.branches("main\nfeat/release\n(HEAD detached at 1a2b3c)\n", remote: false)
    == ["feat/release", "main"])
  #expect(BranchCompare.branches("origin\norigin/HEAD\norigin/main\norigin/feat/x\nupstream/main\n", remote: true)
    == ["feat/x", "main"])
}

@Test func theBranchsCountsCommitsAndFiles() throws {
  let counts = try #require(BranchCompare.counts("3\t6\n"))
  #expect(counts.left == 3 && counts.right == 6)
  #expect(BranchCompare.counts("garbage") == nil)
  #expect(BranchCompare.commits("81380ed\u{1f}feat(release): build\n80e4ef5\u{1f}chore: a · b\n")
    == [.init(hash: "81380ed", subject: "feat(release): build"), .init(hash: "80e4ef5", subject: "chore: a · b")])
  #expect(BranchCompare.fileStats("147\t0\tscripts/release.sh\0" + "-\t-\tlogo.png\0" + "2\t6\tscripts/build.sh\0")
    == [.init(path: "scripts/release.sh", additions: 147, deletions: 0),
        .init(path: "logo.png", additions: 0, deletions: 0, binary: true),
        .init(path: "scripts/build.sh", additions: 2, deletions: 6)])
  let totals = BranchCompare.totals(BranchCompare.fileStats("147\t0\ta\0" + "2\t6\tb\0"))
  #expect(totals.additions == 149 && totals.deletions == 6)
  #expect(BranchCompare.countsLine(commits: 6, files: 19) == "6 commits · 19 files")
  #expect(BranchCompare.countsLine(commits: 1, files: 1) == "1 commit · 1 file")
  #expect(BranchCompare.aheadLine(ahead: 6, behind: 0, base: "main") == "6 commits ahead of main, 0 behind")
  #expect(BranchCompare.aheadLine(ahead: 1, behind: 2, base: "dev") == "1 commit ahead of dev, 2 behind")
}

@Test func mergeTreeSaysWhetherItMergesCleanly() {
  #expect(BranchCompare.merge(status: 0, output: "d0aa45e\n") == .clean)
  #expect(BranchCompare.merge(status: 1, output: "d0aa45e\nf.txt\nsrc/b.swift\n") == .conflicts(["f.txt", "src/b.swift"]))
  #expect(BranchCompare.merge(status: 128, output: "") == .unknown)
}

@Test func theBranchIsPushedWhenGitHubsCopyMatches() {
  #expect(BranchCompare.pushed(status: 0, output: "0\t0\n") == .current)
  #expect(BranchCompare.pushed(status: 0, output: "1\t3\n") == .ahead(3, behind: 1))
  #expect(BranchCompare.pushed(status: 128, output: "") == .notPushed)
}

@Test func addedLinesShapedLikeKeysArePossibleSecrets() {
  let diff = PullRequestDiff.parse("""
    diff --git a/.env b/.env
    --- a/.env
    +++ b/.env
    @@ -1,1 +1,6 @@
     NAME=glance
    +GITHUB=ghp_abcdefghijklmnopqrstuvwxyz0123456789
    +ANTHROPIC=sk-ant-api03-abcdefghijklmnopqrstuvwxyz
    +OPENAI=sk-proj-abcdefghijklmnopqrstuvwxyz
    +AWS=AKIAABCDEFGHIJKLMNOP
    +-----BEGIN OPENSSH PRIVATE KEY-----
    """)
  #expect(BranchCompare.secrets(in: diff) == [
    .init(path: ".env", line: 2, kind: "GitHub token"), .init(path: ".env", line: 3, kind: "Anthropic key"),
    .init(path: ".env", line: 4, kind: "OpenAI key"), .init(path: ".env", line: 5, kind: "AWS access key"),
    .init(path: ".env", line: 6, kind: "Private key"),
  ])
  #expect(BranchCompare.secrets(in: PullRequestDiff.parse("""
    diff --git a/a.swift b/a.swift
    --- a/a.swift
    +++ b/a.swift
    @@ -1,1 +1,2 @@
     let a = 1
    +let skip = "sk-short"
    """)).isEmpty)
}

@Test func theProjectsTestCommandComesFromItsFiles() {
  func project(_ files: [String: String]) -> (String) -> String? { { files[$0] } }
  #expect(BranchCompare.testCommand(project(["Package.swift": "// swift-tools-version:6.0"])) == "swift test")
  #expect(BranchCompare.testCommand(project(["package.json": #"{"scripts":{"test":"vitest run"}}"#])) == "npm test")
  #expect(BranchCompare.testCommand(project([
    "package.json": #"{"scripts":{"test":"echo \"Error: no test specified\" && exit 1"}}"#])) == nil)
  #expect(BranchCompare.testCommand(project(["Cargo.toml": "[package]"])) == "cargo test")
  #expect(BranchCompare.testCommand(project(["go.mod": "module x"])) == "go test ./...")
  #expect(BranchCompare.testCommand(project(["Makefile": "build:\n\tcc a.c\ntest: build\n\t./a.out\n"])) == "make test")
  #expect(BranchCompare.testCommand(project(["Makefile": "build:\n"])) == nil)
}

@Test func createAsksGhAndReadsTheNewNumber() {
  #expect(BranchCompare.createArguments(repository: "o/r", base: "main", head: "feat/release", title: "Release",
                                        draft: true, reviewers: ["mira-k", "devon"], labels: ["release"])
    == ["pr", "create", "--repo", "o/r", "--base", "main", "--head", "feat/release", "--title", "Release",
        "--body-file", "-", "--assignee", "@me", "--draft", "--reviewer", "mira-k,devon", "--label", "release"])
  #expect(!BranchCompare.createArguments(repository: "o/r", base: "main", head: "f", title: "T", draft: false,
                                         reviewers: [], labels: []).contains("--draft"))
  #expect(BranchCompare.createdNumber("Creating pull request for feat into main in o/r\n\nhttps://github.com/o/r/pull/52\n")
    == 52)
  #expect(BranchCompare.createdNumber("nothing") == nil)
  #expect(BranchCompare.failure("To github.com:o/r.git\n ! [rejected] f -> f (fetch first)\n")
    == "! [rejected] f -> f (fetch first)")
  #expect(BranchCompare.defaultTitle([.init(hash: "a", subject: "Fix the badge")]) == "Fix the badge")
  #expect(BranchCompare.defaultTitle([.init(hash: "a", subject: "x"), .init(hash: "b", subject: "y")]) == "")
}
