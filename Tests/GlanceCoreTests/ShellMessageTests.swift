import Foundation
import Testing
@testable import GlanceCore

@Test func escapingRoundTripsHostileFields() {
  for field in ["", "plain", "a\tb", "x\ny", #"back\slash"#, #"literal \n not a newline"#, "\\", "\\\\t", "émoji 🍕",
                "\t\n\\", "trailing\\"] {
    let escaped = ShellWire.escape(field)
    #expect(!escaped.contains("\t") && !escaped.contains("\n"))
    #expect(ShellWire.unescape(escaped) == field)
  }
}

@Test func fieldsKeepEmptyOnesAndUnescape() {
  #expect(ShellWire.fields("a\t\tb") == ["a", "", "b"])
  #expect(ShellWire.fields("line\t3\t2\tgit\\tch") == ["line", "3", "2", "git\tch"])
  #expect(ShellWire.fields("end\t") == ["end", ""])
  #expect(ShellWire.line(["a", "b\tc", "d\ne"]) == "a\tb\\tc\td\\ne\n")
}

@Test func linesSplitAcrossReadsWithoutTrimming() {
  var lines = ShellLines()
  #expect(lines.append(Data("line\t1\t0\t  ".utf8)) == [])
  #expect(lines.append(Data("\nprompt\t2\t/p\n\nbye".utf8)) == ["line\t1\t0\t  ", "prompt\t2\t/p"])
  #expect(lines.append(Data("\n".utf8)) == ["bye"])
}

@Test func decodesWhatThePluginSends() {
  let hello = ShellEvent(line: "hello\t1\tT1\t38099\t/dev/ttys009\t5.9\ttab\tfzf-tab\t/usr/bin:/bin")
  #expect(hello == .hello(ShellHello(protocolVersion: 1, tab: "T1", pid: 38099, tty: "/dev/ttys009", zshVersion: "5.9",
                                     keys: ["tab"], plugins: ["fzf-tab"], path: "/usr/bin:/bin")))
  let withHistory = ShellEvent(line: "hello\t1\tT1\t9\t/dev/ttys1\t5.9\ttab,up\t\t/bin\t/Users/u/.zsh_history")
  guard case .hello(let h) = withHistory else { Issue.record("no hello"); return }
  #expect(h.historyFile == "/Users/u/.zsh_history" && h.keys == ["tab", "up"])
  #expect(ShellEvent(line: "hello\t1\tT1\t1\t/dev/ttys1\t5.9\t\t\t") == .hello(ShellHello(
    protocolVersion: 1, tab: "T1", pid: 1, tty: "/dev/ttys1", zshVersion: "5.9", keys: [], plugins: [], path: "")))
  #expect(ShellEvent(line: "prompt\t8\t/Users/u/p") == .prompt(seq: 8, folder: "/Users/u/p"))
  #expect(ShellEvent(line: "line\t7\t6\tgit ch") == .line(seq: 7, cursor: 6, text: "git ch"))
  #expect(ShellEvent(line: "line\t9\t0\t") == .line(seq: 9, cursor: 0, text: ""))
  #expect(ShellEvent(line: "exec\t/p\t1791479825.758\ttrue") == .exec(folder: "/p", start: 1791479825.758, command: "true"))
  #expect(ShellEvent(line: "exec\t/p\t1.5\t echo hidden") == .exec(folder: "/p", start: 1.5, command: " echo hidden"))
  #expect(ShellEvent(line: "done\t1\t1791479826.05") == .done(exit: 1, end: 1791479826.05))
  #expect(ShellEvent(line: "candidates\t1\t7\t8") == .candidates(request: 1, seq: 7, total: 8))
  #expect(ShellEvent(line: "end\t1") == .candidatesEnd(request: 1))
  #expect(ShellEvent(line: "open\thistory\t4") == .open(.history, seq: 4))
  #expect(ShellEvent(line: "bye") == .bye)
  #expect(ShellEvent(line: "names\tcommands\tls\tgit\tcd") == .names(kind: "commands", names: ["ls", "git", "cd"]))
  #expect(ShellEvent(line: "names\taliases") == .names(kind: "aliases", names: []))
}

@Test func decodesACandidateRow() {
  let row = "cand\t1\t2\tmain porcelain command\tmain-porcelain-commands\tcheckout\t"
    + "checkout         -- checkout branch or paths to working tree\t\t4\t"
  guard case .candidate(let request, let candidate) = ShellEvent(line: row) else {
    Issue.record("not a candidate")
    return
  }
  #expect(request == 1)
  #expect(candidate.index == 2)
  #expect(candidate.word == "checkout")
  #expect(candidate.detail == "checkout branch or paths to working tree")
}

@Test func ignoresUnknownOrShortLines() {
  for line in ["", "nope", "line\t1", "line\tx\t1\tt", "done\tx\t1", "hello\t1\tT", "candidates\t1", "open\tsideways\t1",
               "exec\t/p\tnot-a-time\tls"] {
    #expect(ShellEvent(line: line) == nil, "\(line)")
  }
}

@Test func commandsAreOneLineThatSplitsBack() {
  let commands: [ShellCommand] = [
    .config(features: ["tab", "ghost"]), .accept(request: 3, index: 12), .complete(seq: 9),
    .replace(seq: 4, text: "git status\t--short\nnext", cursor: 10), .run(seq: 5, text: "echo hi"),
    .suggest(seq: 6, text: "atus", cursor: nil), .suggest(seq: 6, text: "commit -m \"\"", cursor: 11),
    .marks(seq: 7, ranges: [ShellMark(start: 0, end: 3, kind: "unknown"), ShellMark(start: 9, end: 10, kind: "quote")]),
    .marks(seq: 8, ranges: []),
  ]
  for command in commands {
    let line = command.line
    #expect(line.hasSuffix("\n"))
    #expect(line.dropLast().contains("\n") == false)
  }
  #expect(ShellCommand.config(features: ["tab", "ghost"]).line == "config\ttab,ghost\n")
  #expect(ShellCommand.accept(request: 3, index: 12).line == "accept\t3\t12\n")
  #expect(ShellWire.fields(String(ShellCommand.replace(seq: 4, text: "a\tb", cursor: 1).line.dropLast()))
    == ["replace", "4", "a\tb", "1"])
  #expect(ShellCommand.suggest(seq: 6, text: "atus", cursor: nil).line == "suggest\t6\tatus\t\n")
  #expect(ShellCommand.fallback(seq: 3, key: "up").line == "fallback\t3\tup\n")
  #expect(ShellCommand.marks(seq: 7, ranges: [ShellMark(start: 0, end: 3, kind: "unknown")]).line
    == "marks\t7\t0-3-unknown\n")
}

@Test func studioTakesOnlyTheTabsOwnShell() {
  let hello = ShellHello(protocolVersion: 1, tab: "T", pid: 500, tty: "/dev/ttys004", zshVersion: "5.9", keys: [],
                         plugins: [], path: "")
  #expect(ShellBridgePolicy.accepts(hello, peerPID: 500, foregroundPID: 500, tty: "/dev/ttys004"))
  // Someone else on the socket claiming the shell's pid.
  #expect(!ShellBridgePolicy.accepts(hello, peerPID: 501, foregroundPID: 500, tty: "/dev/ttys004"))
  // Not the tab's foreground process (a background job, a stale shell).
  #expect(!ShellBridgePolicy.accepts(hello, peerPID: 500, foregroundPID: 777, tty: "/dev/ttys004"))
  #expect(!ShellBridgePolicy.accepts(hello, peerPID: 500, foregroundPID: nil, tty: "/dev/ttys004"))
  // Another terminal (a tmux pane), or none known.
  #expect(!ShellBridgePolicy.accepts(hello, peerPID: 500, foregroundPID: 500, tty: "/dev/ttys009"))
  #expect(!ShellBridgePolicy.accepts(hello, peerPID: 500, foregroundPID: 500, tty: nil))
  // An unknown peer, or a newer protocol.
  #expect(!ShellBridgePolicy.accepts(hello, peerPID: 0, foregroundPID: 500, tty: "/dev/ttys004"))
  let future = ShellHello(protocolVersion: 2, tab: "T", pid: 500, tty: "/dev/ttys004", zshVersion: "5.9", keys: [],
                          plugins: [], path: "")
  #expect(!ShellBridgePolicy.accepts(future, peerPID: 500, foregroundPID: 500, tty: "/dev/ttys004"))
}
