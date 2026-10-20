import Foundation
import Testing
@testable import GlanceCore

@Test func gitIsAskedAboutTheWorkingTreeWithoutTakingTheIndexLock() {
  #expect(WorkingChanges.numstatArguments == ["diff", "HEAD", "--numstat", "--no-renames", "--no-ext-diff", "-z"])
  #expect(WorkingChanges.untrackedArguments == ["ls-files", "--others", "--exclude-standard", "--full-name", "-z"])
  #expect(WorkingChanges.rootArguments == ["rev-parse", "--show-toplevel"])
  #expect(WorkingChanges.environment == ["GIT_OPTIONAL_LOCKS": "0"])
}

@Test func trackedAndUntrackedFilesAddUp() {
  let summary = WorkingChanges.summary(numstat: "12\t3\tSources/A.swift\0-\t-\tassets/logo.png\0",
                                       untracked: "notes.md\0new/B.swift\0",
                                       lines: ["notes.md": 10, "new/B.swift": 40])
  #expect(summary == WorkingChanges.Summary(files: 4, additions: 62, deletions: 3))
}

@Test func anUntrackedFileGitAlsoListsCountsOnce() {
  let summary = WorkingChanges.summary(numstat: "1\t0\ta.txt\0", untracked: "a.txt\0", lines: ["a.txt": 5])
  #expect(summary == WorkingChanges.Summary(files: 1, additions: 1, deletions: 0))
}

@Test func aCleanTreeHasNoChanges() {
  let summary = WorkingChanges.summary(numstat: "", untracked: "", lines: [:])
  #expect(summary.isClean)
  #expect(!WorkingChanges.Summary(files: 1, additions: 0, deletions: 0).isClean)
}

@Test func aTextFilesLinesAreItsNewlinesPlusAnUnfinishedLastOne() {
  #expect(WorkingChanges.lineCount(Data("a\nb\n".utf8)) == 2)
  #expect(WorkingChanges.lineCount(Data("a\nb".utf8)) == 2)
  #expect(WorkingChanges.lineCount(Data()) == 0)
  #expect(WorkingChanges.lineCount(Data([0x61, 0x00, 0x0A])) == nil) // binary
}

@Test func theSummaryReadsAsASentence() {
  #expect(WorkingChanges.Summary(files: 25, additions: 282, deletions: 385).sentence(folder: "glance")
    == "25 files changed in glance: 282 lines added, 385 removed")
  #expect(WorkingChanges.Summary(files: 1, additions: 1, deletions: 0).sentence(folder: "x")
    == "1 file changed in x: 1 line added, 0 removed")
}
