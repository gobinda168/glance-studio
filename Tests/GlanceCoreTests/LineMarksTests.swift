import Foundation
import Testing
@testable import GlanceCore

private let known: Set<String> = ["git", "ls", "echo", "sudo", "env", "grep", "make", "cd", "true", "nohup"]
// Studio's check also takes executable paths; here any path counts.
private func isKnown(_ word: String) -> Bool { known.contains(word) || word.contains("/") }

private func marks(_ line: String, cursor: Int? = nil) -> [ShellMark] {
  LineMarks.marks(line: line, cursor: cursor ?? line.unicodeScalars.count + 1, isKnown: isKnown)
}

@Test func lexerFindsCommandPositions() {
  let words = ShellLexer.lex("FOO=1 sudo -E env BAR=2 git status | grep x && make; ls >out.txt").words
  let commands = words.filter(\.commandPosition).map(\.text)
  #expect(commands == ["sudo", "env", "git", "grep", "make", "ls"])
  let target = words.first { $0.text == "out.txt" }
  #expect(target?.commandPosition == false)
}

@Test func lexerKeepsQuotedWordsWhole() {
  let result = ShellLexer.lex("echo 'a b' \"c d\" e\\ f")
  #expect(result.words.map(\.text) == ["echo", "'a b'", "\"c d\"", "e\\ f"])
  #expect(result.unclosed == nil)
  #expect(result.words[1].start == 5 && result.words[1].end == 10)
}

@Test func lexerFindsAnUnclosedQuote() {
  #expect(ShellLexer.lex("echo \"hello").unclosed == 5)
  #expect(ShellLexer.lex("echo 'it''s").unclosed == 9)
  #expect(ShellLexer.lex("echo $(date").unclosed == 5)
  #expect(ShellLexer.lex("echo `date").unclosed == 5)
  #expect(ShellLexer.lex("echo \"$(date)\"").unclosed == nil)
  #expect(ShellLexer.lex("echo \\\"").unclosed == nil)
}

@Test func unknownCommandsAreMarkedOnceLeft() {
  #expect(marks("gti status") == [ShellMark(start: 0, end: 3, kind: "unknown")])
  // The cursor is still in the word: not yet.
  #expect(marks("gti", cursor: 3).isEmpty)
  #expect(marks("git status | grpe x") == [ShellMark(start: 13, end: 17, kind: "unknown")])
  #expect(marks("sudo gti") == [ShellMark(start: 5, end: 8, kind: "unknown")])
  #expect(marks("git status").isEmpty)
}

@Test func someWordsAreNeverMarked() {
  for line in ["FOO=1 git x", "$EDITOR file", "./run.sh", "/bin/ls", "~/bin/tool", "(git status)", "{ ls; }",
               "if true; then ls; fi", "for x in a b; do echo $x; done", "!git", "[[ -n x ]]", "\\ls", "'ls'",
               "sudo -u admin ls", "env -u HOME FOO=1 ls", "time ls", "nohup make &", "ls $(gti x)", "echo `gti`",
               "while true; do ls; done", "git log | grep -v x"] {
    #expect(marks(line).isEmpty, "\(line) → \(marks(line))")
  }
}

@Test func anUnclosedQuoteMarksItsOpening() {
  #expect(marks("echo \"hello") == [ShellMark(start: 5, end: 6, kind: "quote")])
  #expect(marks("gti \"x", cursor: 6).contains(ShellMark(start: 0, end: 3, kind: "unknown")))
}

@Test func aLineRunsWhenEveryCommandNameIsKnown() {
  let known: Set<String> = ["pnpm", "git", "sudo", "ls"]
  #expect(LineMarks.runs("pnpm dev && git push") { known.contains($0) })
  #expect(!LineMarks.runs("pnpf dev") { known.contains($0) })
  #expect(!LineMarks.runs("git status | gerp main") { known.contains($0) })
  // Assignments, expansions, reserved words and arguments aren't command names.
  #expect(LineMarks.runs("FOO=1 sudo ls $DIR; if true; then ls; fi") { known.contains($0) || $0 == "true" })
}
