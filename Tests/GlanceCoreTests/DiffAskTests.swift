import Testing
@testable import GlanceCore

private typealias Line = PullRequestDiff.Line
private typealias Anchor = ReviewThreads.Anchor

private let hunkA = PullRequestDiff.Hunk(header: "@@ -10,3 +10,3 @@ func f() {", lines: [
  Line(kind: .context, text: "let a = 1", old: 10, new: 10),
  Line(kind: .removed, text: "let b = 1", old: 11, new: nil),
  Line(kind: .added, text: "let b = 2", old: nil, new: 11),
  Line(kind: .context, text: "return a + b", old: 12, new: 12),
])
private let hunkB = PullRequestDiff.Hunk(header: "@@ -40,2 +40,3 @@", lines: [
  Line(kind: .context, text: "}", old: 40, new: 40),
  Line(kind: .added, text: "// end", old: nil, new: 41),
])

private func file(_ hunks: [PullRequestDiff.Hunk], change: PullRequestDiff.File.Change = .modified,
                  oldPath: String? = nil, binary: Bool = false) -> PullRequestDiff.File {
  PullRequestDiff.File(path: "Sources/App.swift", oldPath: oldPath, change: change, isBinary: binary, oldMode: nil,
                       newMode: nil, hunks: hunks)
}

private let pr = DiffAsk.Subject.pullRequest(number: 48, title: "Cache tokens", repository: "acme/api",
                                             head: "fix/cache", base: "main")

private func marked(_ message: String) -> [String] {
  message.components(separatedBy: "\n").filter { $0.hasPrefix(">") }
}

@Test func oneAddedLineIsMarkedInItsHunk() {
  let message = DiffAsk.message(subject: pr, file: file([hunkA, hunkB]),
                                scope: .lines(start: nil, end: Anchor(side: .right, line: 11)),
                                localClone: false, question: "Why 2?")
  #expect(message.hasPrefix("Pull request #48 \"Cache tokens\" in acme/api (fix/cache → main)."))
  #expect(message.contains("File: Sources/App.swift"))
  #expect(message.contains("The user selected line 11 of the diff (marked >):"))
  #expect(marked(message) == [">" + String(repeating: " ", count: 9) + "11 + let b = 2"])
  #expect(message.contains("@@ -10,3 +10,3 @@ func f() {"))
  #expect(!message.contains("@@ -40,2 +40,3 @@"))
  #expect(message.hasSuffix("Question: Why 2?"))
  #expect(!message.contains("local clone"))
}

@Test func aRemovedLineIsFoundOnTheLeft() {
  let message = DiffAsk.message(subject: pr, file: file([hunkA]),
                                scope: .lines(start: Anchor(side: .left, line: 11), end: Anchor(side: .left, line: 11)),
                                localClone: false, question: "q")
  #expect(marked(message) == [">   11       - let b = 1"])
  #expect(message.contains("line 11"))
}

@Test func aRangeAcrossSidesMarksEverythingBetween() {
  let scope = DiffAsk.Scope.lines(start: Anchor(side: .left, line: 11), end: Anchor(side: .right, line: 12))
  #expect(DiffAsk.selection(file([hunkA]), scope) == 1...3)
  let message = DiffAsk.message(subject: pr, file: file([hunkA]), scope: scope, localClone: false, question: "q")
  #expect(marked(message).count == 3)
  #expect(message.contains("lines 11–12"))
}

@Test func aBackwardsRangeIsPutInOrder() {
  let scope = DiffAsk.Scope.lines(start: Anchor(side: .right, line: 12), end: Anchor(side: .right, line: 10))
  #expect(DiffAsk.selection(file([hunkA]), scope) == 0...3)
}

@Test func aWholeFileSendsEveryHunkUnmarked() {
  let message = DiffAsk.message(subject: pr, file: file([hunkA, hunkB]), scope: .file, localClone: true,
                                question: "What changed?")
  #expect(message.contains("The user asks about this file. Its diff:"))
  #expect(message.contains("@@ -10,3 +10,3 @@ func f() {"))
  #expect(message.contains("@@ -40,2 +40,3 @@"))
  #expect(marked(message).isEmpty)
  #expect(message.contains("Your working folder is a local clone; it may be on another branch than this pull request."))
}

@Test func aSelectionNotInTheDiffSendsTheWholeFile() {
  let scope = DiffAsk.Scope.lines(start: nil, end: Anchor(side: .right, line: 999))
  #expect(DiffAsk.selection(file([hunkA, hunkB]), scope) == nil)
  let message = DiffAsk.message(subject: pr, file: file([hunkA, hunkB]), scope: scope, localClone: false, question: "q")
  #expect(message.contains("The user asks about line 999, which isn't in the diff any more. The file's diff:"))
  #expect(message.contains("@@ -40,2 +40,3 @@"))
}

@Test func aFileWithoutLinesSaysSo() {
  let message = DiffAsk.message(subject: pr, file: file([], change: .renamed, oldPath: "App.swift", binary: true),
                                scope: .file, localClone: false, question: "q")
  #expect(message.contains("File: Sources/App.swift (renamed from App.swift)"))
  #expect(message.contains("(No lines changed: a binary file, or a rename or mode change only.)"))
}

@Test func aBranchIsNotYetAPullRequest() {
  let message = DiffAsk.message(subject: .branch(head: "feat/x", base: "main"), file: file([hunkA]), scope: .file,
                                localClone: true, question: "q")
  #expect(message.hasPrefix("The branch feat/x → main, not yet a pull request."))
  #expect(message.contains("local clone"))
}

@Test func aHugeDiffIsCut() {
  let long = PullRequestDiff.Hunk(header: "@@ -1 +1 @@", lines: [
    Line(kind: .added, text: String(repeating: "x", count: 70_000), old: nil, new: 1),
  ])
  let message = DiffAsk.message(subject: pr, file: file([long]), scope: .file, localClone: false, question: "q")
  #expect(message.contains("[diff cut]"))
  #expect(message.count < DiffAsk.limit + 2_000)
}

@Test func reviewModeReadsOnlyWithItsRules() {
  let arguments = DiffAsk.arguments()
  #expect(arguments.contains("--tools"))
  #expect(arguments.contains("Read") && arguments.contains("Grep") && arguments.contains("Glob"))
  #expect(arguments.contains(#"{"disableAllHooks":true}"#))
  #expect(arguments.contains("--strict-mcp-config"))
  #expect(arguments.last == DiffAsk.rules)
  #expect(InlineAsk.arguments().last == InlineAsk.rules)
}

@Test func placesNameTheLines() {
  #expect(DiffAsk.place(.file) == "this file")
  #expect(DiffAsk.place(.lines(start: nil, end: Anchor(side: .right, line: 4))) == "line 4")
  #expect(DiffAsk.place(.lines(start: Anchor(side: .right, line: 2), end: Anchor(side: .right, line: 4))) == "lines 2–4")
}
