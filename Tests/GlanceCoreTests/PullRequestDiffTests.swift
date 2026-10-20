import Foundation
import Testing
@testable import GlanceCore

/// `git diff --cached -M` in a scratch repository (2026-10-07). It holds:
/// - a deleted file;
/// - a changed one;
/// - a binary one added;
/// - a pure rename, and a rename with a change;
/// - a last line that gained its newline;
/// - a mode change.
private let kinds = #"""
diff --git a/gone.txt b/gone.txt
deleted file mode 100644
index 286c5f5..0000000
--- a/gone.txt
+++ /dev/null
@@ -1 +0,0 @@
-gone
diff --git a/keep.txt b/keep.txt
index b00a0f1..6c61751 100644
--- a/keep.txt
+++ b/keep.txt
@@ -1,8 +1,9 @@
 one
-two
+TWO
 three
 four
 five
 six
 seven
 eight
+nine
diff --git a/logo.png b/logo.png
new file mode 100644
index 0000000..ac6c544
Binary files /dev/null and b/logo.png differ
diff --git a/same.txt b/moved/same.txt
similarity index 100%
rename from same.txt
rename to moved/same.txt
diff --git a/old-name.txt b/new-name.txt
similarity index 80%
rename from old-name.txt
rename to new-name.txt
index 600d48a..cdafba1 100644
--- a/old-name.txt
+++ b/new-name.txt
@@ -1,5 +1,5 @@
 alpha
 beta
-gamma
+GAMMA
 delta
 epsilon
diff --git a/nonl.txt b/nonl.txt
index 1c943a9..de98044 100644
--- a/nonl.txt
+++ b/nonl.txt
@@ -1,3 +1,3 @@
 a
 b
-c
\ No newline at end of file
+c
diff --git a/tool.sh b/tool.sh
old mode 100644
new mode 100755

"""#

/// The same command over a file with an accent (git quotes it, octal bytes and all) and one with a space (git puts a
/// tab after it on the --- and +++ lines); the accented file's line ends in CRLF.
private let awkwardPaths = [
  #"diff --git "a/caf\303\251.txt" "b/caf\303\251.txt""#,
  "new file mode 100644",
  "index 0000000..d45cf1b",
  "--- /dev/null",
  #"+++ "b/caf\303\251.txt""#,
  "@@ -0,0 +1 @@",
  "+bonjour\r",
  "diff --git a/docs/my notes.md b/docs/my notes.md",
  "index 3367afd..3e75765 100644",
  "--- a/docs/my notes.md\t",
  "+++ b/docs/my notes.md\t",
  "@@ -1 +1 @@",
  "-old",
  "+new",
].joined(separator: "\n") + "\n"

@Test func everyKindOfChangeIsReadWithItsPathAndLines() {
  let files = PullRequestDiff.parse(kinds)
  #expect(files.map(\.path) == ["gone.txt", "keep.txt", "logo.png", "moved/same.txt", "new-name.txt", "nonl.txt",
                                "tool.sh"])
  #expect(files.map(\.change) == [.deleted, .modified, .added, .renamed, .renamed, .modified, .modified])
  #expect(files[0].hunks[0].lines == [.init(kind: .removed, text: "gone", old: 1, new: nil)])
  #expect(files[2].isBinary && files[2].hunks.isEmpty)
  #expect(files[3].oldPath == "same.txt" && files[3].hunks.isEmpty)
  #expect(files[4].oldPath == "old-name.txt" && files[4].additions == 1 && files[4].deletions == 1)
  #expect(files[6].oldMode == "100644" && files[6].newMode == "100755" && files[6].hunks.isEmpty)
  #expect(files[1].oldPath == nil && files[1].oldMode == nil)
}

@Test func linesAreNumberedOnBothSides() {
  let keep = PullRequestDiff.parse(kinds)[1]
  #expect(keep.hunks[0].header == "@@ -1,8 +1,9 @@")
  let lines = keep.hunks[0].lines
  #expect(lines[0] == .init(kind: .context, text: "one", old: 1, new: 1))
  #expect(lines[1] == .init(kind: .removed, text: "two", old: 2, new: nil))
  #expect(lines[2] == .init(kind: .added, text: "TWO", old: nil, new: 2))
  #expect(lines[3] == .init(kind: .context, text: "three", old: 3, new: 3))
  #expect(lines.last == .init(kind: .added, text: "nine", old: nil, new: 9))
  #expect(keep.additions == 2 && keep.deletions == 1)
}

@Test func aMissingFinalNewlineMarksItsLine() {
  let lines = PullRequestDiff.parse(kinds)[5].hunks[0].lines
  #expect(lines.map(\.text) == ["a", "b", "c", "c"])
  #expect(lines.map(\.noNewline) == [false, false, true, false])
}

@Test func quotedAndSpacedPathsAreTheRealOnes() {
  let files = PullRequestDiff.parse(awkwardPaths)
  #expect(files.map(\.path) == ["café.txt", "docs/my notes.md"])
  #expect(files[0].change == .added)
  #expect(files[0].hunks[0].lines == [.init(kind: .added, text: "bonjour", old: nil, new: 1)])
  #expect(files[1].hunks[0].lines.map(\.text) == ["old", "new"])
}

@Test func anEmptyLineInsideAHunkIsContext() {
  let text = ["diff --git a/a.txt b/a.txt", "--- a/a.txt", "+++ b/a.txt", "@@ -1,3 +1,3 @@", " one", "", "-three",
              "+THREE"].joined(separator: "\n")
  let lines = PullRequestDiff.parse(text)[0].hunks[0].lines
  #expect(lines.map(\.kind) == [.context, .context, .removed, .added])
  #expect(lines[1] == .init(kind: .context, text: "", old: 2, new: 2))
}

@Test func somethingThatIsntADiffHasNoFiles() {
  #expect(PullRequestDiff.parse("").isEmpty)
  #expect(PullRequestDiff.parse("HTTP 406: Sorry, the diff exceeded the maximum number of files (300).").isEmpty)
}

@Test func aFileOverFifteenHundredChangedLinesIsLarge() {
  let lines = (1...1_501).map { "+line \($0)" }
  let text = (["diff --git a/big.txt b/big.txt", "new file mode 100644", "--- /dev/null", "+++ b/big.txt",
               "@@ -0,0 +1,1501 @@"] + lines).joined(separator: "\n")
  let big = PullRequestDiff.parse(text)[0]
  #expect(big.additions == 1_501 && big.isLarge)
  #expect(!PullRequestDiff.parse(kinds)[1].isLarge)
}

@Test func theSplitViewPairsRemovedLinesWithTheAddedOnesAfterThem() {
  let text = ["diff --git a/a.txt b/a.txt", "--- a/a.txt", "+++ b/a.txt", "@@ -1,5 +1,5 @@", " a", "-b", "-c", "+B",
              " d", "-e", "+E", "+F"].joined(separator: "\n")
  let rows = PullRequestDiff.rows(PullRequestDiff.parse(text)[0].hunks[0])
  #expect(rows.map { [$0.left?.text, $0.right?.text] } == [
    ["a", "a"], ["b", "B"], ["c", nil], ["d", "d"], ["e", "E"], [nil, "F"],
  ])
  let crossed = ["diff --git a/a.txt b/a.txt", "--- a/a.txt", "+++ b/a.txt", "@@ -1,2 +1,2 @@", "-x", "+y", "-z", "+w"]
    .joined(separator: "\n")
  #expect(PullRequestDiff.rows(PullRequestDiff.parse(crossed)[0].hunks[0]).map { [$0.left?.text, $0.right?.text] }
    == [["x", "y"], ["z", "w"]])
}

@Test func theSideBarGroupsFilesByFolderWithTheRootLast() {
  #expect(PullRequestDiff.folders(["README.md", "scripts/release.sh", "Sources/Glance/App.swift", "scripts/build.sh"])
    == [
      .init(path: "scripts/", files: ["scripts/release.sh", "scripts/build.sh"]),
      .init(path: "Sources/Glance/", files: ["Sources/Glance/App.swift"]),
      .init(path: "./", files: ["README.md"]),
    ])
}

@Test func aSuggestionsLinesComeFromTheNewSide() {
  let keep = PullRequestDiff.parse(kinds)[1]
  #expect(PullRequestDiff.newLines(keep, from: 2, to: 3) == ["TWO", "three"])
  #expect(PullRequestDiff.newLines(keep, from: 40, to: 41).isEmpty)
}

@Test func ghIsAskedForThePullRequestsOrACommitsDiff() {
  #expect(PullRequestDiff.arguments(number: 51, repository: "gobinda168/glance")
    == ["pr", "diff", "51", "--repo", "gobinda168/glance"])
  #expect(PullRequestDiff.commitArguments(sha: "be35448", repository: "gobinda168/glance")
    == ["api", "repos/gobinda168/glance/commits/be35448", "-H", "Accept: application/vnd.github.diff"])
}
