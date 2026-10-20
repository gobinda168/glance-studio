import Darwin
import Foundation
import Testing
@testable import GlanceCore

/// The zsh plugin against a real `zsh -i` (spec "Testing"). Each test starts its own shell.
@Suite(.serialized) struct ShellPluginTests {
  private func gitRepo() throws -> URL {
    let repo = URL(fileURLWithPath: "/tmp/glr-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    let git = Process()
    git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    git.arguments = ["init", "-q", repo.path]
    try git.run()
    git.waitUntilExit()
    return repo
  }

  @Test func helloAndConfig() throws {
    let shell = try PluginShell()
    defer { shell.stop() }
    let hello = try shell.start()
    #expect(hello.protocolVersion == 1)
    #expect(hello.tab.hasPrefix("TAB-"))
    #expect(hello.tty.hasPrefix("/dev/ttys"))
    #expect(hello.keys.contains("tab"))
    #expect(hello.path.contains("/usr/bin"))
    #expect(hello.zshVersion.hasPrefix("5."))
  }

  @Test func pluginStaysOffWithoutTheEnvironment() throws {
    let shell = try PluginShell(glance: false)
    defer { shell.stop() }
    shell.type("echo ready-$((40+2))\r")
    try shell.waitScreen("ready-42")
    // Tab is zsh's own: a unique file completes in place.
    try "x".write(to: shell.folder.appendingPathComponent("uniquefile.txt"), atomically: true, encoding: .utf8)
    shell.type("cat uniq\t")
    try shell.waitScreen("cat uniquefile.txt")
  }

  @Test func tabCollectsGitSubcommands() throws {
    let repo = try gitRepo()
    defer { try? FileManager.default.removeItem(at: repo) }
    let shell = try PluginShell(cwd: repo)
    defer { shell.stop() }
    try shell.start()
    let (_, candidates) = try shell.tab("git ch")
    let names = candidates.map(\.name)
    #expect(names.contains("checkout") && names.contains("cherry-pick"))
    let checkout = try #require(candidates.first { $0.name == "checkout" })
    #expect(!checkout.detail.isEmpty)
    #expect(!checkout.group.isEmpty)
    #expect(checkout.kind == .command)
    #expect(checkout.start == 4)
    try shell.waitLine("git che")
  }

  @Test func acceptInsertsTheCandidate() throws {
    let repo = try gitRepo()
    defer { try? FileManager.default.removeItem(at: repo) }
    let shell = try PluginShell(cwd: repo)
    defer { shell.stop() }
    try shell.start()
    let (request, candidates) = try shell.tab("git ch")
    let checkout = try #require(candidates.first { $0.name == "checkout" })
    shell.send(.accept(request: request, index: checkout.index))
    try shell.waitLine("git checkout ")
  }

  @Test func acceptQuotesAFileWithSpaces() throws {
    let shell = try PluginShell()
    defer { shell.stop() }
    for name in ["my file.txt", "my other.txt"] {
      try "x".write(to: shell.folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    try shell.start()
    let (request, candidates) = try shell.tab("cat my")
    let file = try #require(candidates.first { $0.name == "my file.txt" })
    #expect(file.word == #"my\ file.txt"#)
    #expect(file.kind == .file)
    shell.send(.accept(request: request, index: file.index))
    try shell.waitLine(#"cat my\ file.txt "#)
  }

  @Test func foldersAreFlaggedForAbsoluteAndTildePaths() throws {
    let home = URL(fileURLWithPath: "/tmp/glh-\(UUID().uuidString.prefix(8))", isDirectory: true)
    for name in ["Lab", "Lib"] {
      try FileManager.default.createDirectory(at: home.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: home) }
    let shell = try PluginShell(environment: ["HOME": home.path])
    defer { shell.stop() }
    try shell.start()
    let (_, absolute) = try shell.tab("ls /usr/s")
    let share = try #require(absolute.first { $0.name == "share" })
    #expect(share.isDirectory && share.kind == .folder)
    #expect(share.hidden == "/usr/")
    #expect(CompletionFilter.query(line: "ls /usr/s", cursor: 9, start: share.start, hidden: share.hidden) == "s")
    try shell.clearLine()
    let (_, tilde) = try shell.tab("ls ~/L")
    #expect(tilde.contains { $0.name == "Lib" && $0.isDirectory && $0.hidden == "~/" })
  }

  @Test func optionsCarryDescriptions() throws {
    let shell = try PluginShell()
    defer { shell.stop() }
    try shell.start()
    let (_, options) = try shell.tab("ls -")
    #expect(options.count > 10)
    #expect(options.allSatisfy { $0.kind == .option })
    #expect(options.contains { $0.name == "-a" && !$0.detail.isEmpty })
  }

  @Test func staleAcceptIsIgnored() throws {
    let repo = try gitRepo()
    defer { try? FileManager.default.removeItem(at: repo) }
    let shell = try PluginShell(cwd: repo)
    defer { shell.stop() }
    try shell.start()
    let (request, candidates) = try shell.tab("git ch")
    let checkout = try #require(candidates.first { $0.name == "checkout" })
    shell.send(.accept(request: request + 7, index: checkout.index))
    shell.send(.accept(request: request, index: 9999))
    Thread.sleep(forTimeInterval: 0.4)
    #expect(shell.lastLine?.text == "git che")
  }

  @Test func completeRunsAgainAfterAFolder() throws {
    let shell = try PluginShell()
    defer { shell.stop() }
    try shell.start()
    let (request, candidates) = try shell.tab("ls /usr/s")
    let share = try #require(candidates.first { $0.name == "share" })
    shell.clear()
    shell.send(.accept(request: request, index: share.index))
    try shell.waitLine("ls /usr/share/")
    let seq = try #require(shell.lastLine?.seq)
    shell.clear()
    shell.send(.complete(seq: seq))
    try shell.wait("candidates for /usr/share") { if case .candidatesEnd = $0 { true } else { false } }
    #expect(shell.events.contains { if case .candidate(_, let c) = $0 { c.hidden == "/usr/share/" } else { false } })
  }

  @Test func execAndDone() throws {
    let shell = try PluginShell()
    defer { shell.stop() }
    try shell.start()
    shell.clear()
    shell.type("true\r")
    try shell.wait("done 0") { if case .done(0, _) = $0 { true } else { false } }
    shell.type("false\r")
    try shell.wait("done 1") { if case .done(1, _) = $0 { true } else { false } }
    shell.type(" echo quiet\r")
    try shell.wait("exec of the spaced command") { if case .exec(_, _, " echo quiet") = $0 { true } else { false } }
    let execs = shell.events.compactMap { if case .exec(let folder, let start, let command) = $0 { (folder, start, command) } else { nil } }
    #expect(execs.map(\.2) == ["true", "false", " echo quiet"])
    let here = (shell.folder.path as NSString).resolvingSymlinksInPath
    #expect(execs.allSatisfy { ($0.0 as NSString).resolvingSymlinksInPath == here })
    #expect(execs.allSatisfy { $0.1 > 1_700_000_000 })
  }

  @Test func replaceRunAndStaleSeq() throws {
    let shell = try PluginShell()
    defer { shell.stop() }
    try shell.start()
    shell.clear()
    shell.type("x")
    try shell.waitLine("x")
    let seq = try #require(shell.lastLine?.seq)
    shell.send(.replace(seq: seq - 1, text: "STALE", cursor: 2))
    Thread.sleep(forTimeInterval: 0.3)
    #expect(shell.lastLine?.text == "x")
    shell.send(.replace(seq: seq, text: "echo replaced", cursor: 4))
    try shell.waitLine("echo replaced")
    #expect(shell.lastLine?.cursor == 4)
    // Tabs, newlines and backslashes survive the trip both ways.
    let hostile = "printf 'a\tb\\n'\necho \\done"
    shell.send(.replace(seq: try #require(shell.lastLine?.seq), text: hostile, cursor: 3))
    try shell.waitLine(hostile)
    let now = try #require(shell.lastLine?.seq)
    shell.send(.run(seq: now, text: "echo ran-it-$((1+1))"))
    shell.type("\u{1b}[9999~")
    try shell.wait("the run") { if case .exec(_, _, "echo ran-it-$((1+1))") = $0 { true } else { false } }
    try shell.waitScreen("ran-it-2")
  }

  @Test func suggestAndMarksDraw() throws {
    let shell = try PluginShell()
    defer { shell.stop() }
    try shell.start(features: ["tab", "ghost", "marks"])
    shell.type("gti st")
    try shell.waitLine("gti st")
    let seq = try #require(shell.lastLine?.seq)
    shell.clear()
    shell.send(.suggest(seq: seq, text: "atus", cursor: nil))
    shell.send(.marks(seq: seq, ranges: [ShellMark(start: 0, end: 3, kind: "unknown")]))
    try shell.waitScreen("atus")
    try shell.waitScreen("\u{1b}[4m")
    // Typing into the ghost text keeps the rest of it, without a new suggestion; typing off it clears it.
    shell.clear()
    shell.type("a")
    try shell.waitLine("gti sta")
    shell.send(.ping)
    try shell.wait("state with tus") { if case .state(_, _, "gti sta", "tus") = $0 { true } else { false } }
    shell.clear()
    shell.type("x")
    try shell.waitLine("gti stax")
    shell.send(.ping)
    try shell.wait("state without ghost") { if case .state(_, _, "gti stax", "") = $0 { true } else { false } }
  }

  @Test func aForeignTabBindingIsLeftAlone() throws {
    let shell = try PluginShell(zshrc: "mine() { BUFFER+=MINE }; zle -N mine; bindkey '^I' mine")
    defer { shell.stop() }
    let hello = try shell.start()
    #expect(!hello.keys.contains("tab"))
    shell.type("x\t")
    try shell.waitLine("xMINE")
  }

  @Test func tabFallsBackWhenStudioGoesAway() throws {
    let shell = try PluginShell()
    defer { shell.stop() }
    try "x".write(to: shell.folder.appendingPathComponent("lonelyfile.txt"), atomically: true, encoding: .utf8)
    try shell.start()
    shell.type("sleep 1\r")
    Thread.sleep(forTimeInterval: 0.3)
    shell.dropConnection()
    Thread.sleep(forTimeInterval: 1.2)
    shell.type("echo alive-$((2*21))\r")
    try shell.waitScreen("alive-42")
    #expect(shell.isRunning)
    shell.type("cat lonel\t")
    try shell.waitScreen("cat lonelyfile.txt")
  }

  @Test func worksThroughGhosttysIntegration() throws {
    let repo = try gitRepo()
    defer { try? FileManager.default.removeItem(at: repo) }
    let shell = try PluginShell(cwd: repo, loader: .ghostty)
    defer { shell.stop() }
    let hello = try shell.start()
    #expect(hello.keys.contains("tab"))
    #expect(shell.screen.contains("\u{1b}]133;"))
    let (request, candidates) = try shell.tab("git ch")
    let checkout = try #require(candidates.first { $0.name == "checkout" })
    shell.send(.accept(request: request, index: checkout.index))
    try shell.waitLine("git checkout ")
    try shell.clearLine()
    shell.type("false\r")
    try shell.wait("done 1") { if case .done(1, _) = $0 { true } else { false } }
    try shell.waitScreen("\u{1b}]133;D;1")
  }

  // MARK: - S2: ↑ and ⌃R

  private func isOpen(_ what: ShellOpen) -> (ShellEvent) -> Bool {
    { if case .open(what, _) = $0 { true } else { false } }
  }

  @Test func upAndCtrlROpenStudiosLists() throws {
    let shell = try PluginShell()
    defer { shell.stop() }
    let hello = try shell.start(features: ["tab", "up", "search"])
    #expect(hello.keys.isSuperset(of: ["tab", "up", "ctrl-r"]))
    #expect(hello.historyFile?.hasSuffix("history") == true)
    shell.clear()
    shell.type("\u{1b}[A")
    try shell.wait("open history", isOpen(.history))
    shell.clear()
    shell.type("\u{1b}OA") // application cursor mode's ↑ (macOS's /etc/zshrc binds it to up-line-or-search)
    try shell.wait("open history", isOpen(.history))
    shell.clear()
    shell.type("\u{12}")
    try shell.wait("open search", isOpen(.search))
  }

  @Test func upInsideAMultiLineBufferMovesUp() throws {
    let shell = try PluginShell()
    defer { shell.stop() }
    try shell.start(features: ["up"])
    shell.type("x")
    try shell.waitLine("x")
    let seq = try #require(shell.lastLine?.seq)
    shell.send(.replace(seq: seq, text: "echo one\necho two", cursor: 17))
    try shell.waitLine("echo one\necho two")
    shell.clear()
    shell.type("\u{1b}[A")
    try shell.wait("the cursor on the first line") {
      if case .line(_, let cursor, _) = $0 { cursor < 9 } else { false }
    }
    #expect(!shell.events.contains(where: isOpen(.history)))
  }

  @Test func upIsZshsOwnWhenTheFeatureIsOff() throws {
    let shell = try PluginShell()
    defer { shell.stop() }
    try shell.start(features: ["tab"])
    shell.type("echo first-thing\r")
    try shell.wait("done") { if case .done = $0 { true } else { false } }
    shell.clear()
    shell.type("\u{1b}[A")
    try shell.waitLine("echo first-thing")
    #expect(!shell.events.contains(where: isOpen(.history)))
  }

  @Test func fallbackRunsWhatTheKeyDidBefore() throws {
    let shell = try PluginShell()
    defer { shell.stop() }
    try shell.start(features: ["up"])
    shell.type("echo recalled\r")
    try shell.wait("done") { if case .done = $0 { true } else { false } }
    shell.clear()
    shell.type("\u{1b}[A")
    guard case .open(_, let seq) = try shell.wait("open history", isOpen(.history)) else { return }
    shell.send(.fallback(seq: seq, key: "up"))
    try shell.waitLine("echo recalled")
  }

  @Test func aUserUpBindingIsLeftAlone() throws {
    let shell = try PluginShell(zshrc: "mine() { BUFFER=MINE }; zle -N mine; bindkey '^[[A' mine; bindkey '^[OA' mine")
    defer { shell.stop() }
    let hello = try shell.start(features: ["up"])
    #expect(!hello.keys.contains("up"))
    shell.type("\u{1b}[A")
    try shell.waitLine("MINE")
  }

  // MARK: - S3: names and accepting ghost text

  @Test func namesArriveAfterHello() throws {
    let shell = try PluginShell()
    defer { shell.stop() }
    try shell.start(features: ["ghost"])
    try shell.wait("command names") { if case .names("commands", let names) = $0 { names.contains("ls") } else { false } }
    try shell.wait("builtins") { if case .names("builtins", let names) = $0 { names.contains("cd") } else { false } }
  }

  private func ghostLine(_ shell: PluginShell, _ text: String) throws -> Int {
    shell.type(text)
    try shell.waitLine(text)
    return try #require(shell.lastLine?.seq)
  }

  @Test func rightArrowAndWordAcceptTheGhostText() throws {
    let shell = try PluginShell()
    defer { shell.stop() }
    try shell.start(features: ["ghost"])
    let seq = try ghostLine(shell, "git st")
    shell.send(.suggest(seq: seq, text: "atus --short", cursor: nil))
    shell.send(.ping)
    try shell.wait("ghost shown") { if case .state(_, _, "git st", "atus --short") = $0 { true } else { false } }
    shell.type("\u{1b}f") // ⌥→
    try shell.waitLine("git status")
    shell.clear()
    shell.send(.ping)
    try shell.wait("the rest stays") { if case .state(_, _, "git status", " --short") = $0 { true } else { false } }
    shell.type("\u{1b}[C") // →
    try shell.waitLine("git status --short")
    #expect(shell.lastLine?.cursor == 18)
  }

  @Test func rightArrowMidLineMovesTheCursor() throws {
    let shell = try PluginShell()
    defer { shell.stop() }
    try shell.start(features: ["ghost"])
    let seq = try ghostLine(shell, "abc")
    shell.send(.suggest(seq: seq, text: "def", cursor: nil))
    shell.type("\u{1b}[D") // ←
    try shell.wait("cursor at 2") { if case .line(_, 2, "abc") = $0 { true } else { false } }
    shell.clear()
    shell.type("\u{1b}[C") // → moves, doesn't accept
    try shell.wait("cursor at 3") { if case .line(_, 3, "abc") = $0 { true } else { false } }
  }

  @Test func acceptingLeavesTheCursorWhereStudioSaid() throws {
    let shell = try PluginShell()
    defer { shell.stop() }
    try shell.start(features: ["ghost"])
    let seq = try #require(shell.lastLine?.seq ?? shell.events.compactMap { if case .prompt(let s, _) = $0 { s } else { nil } }.last)
    shell.send(.suggest(seq: seq, text: "git commit -m \"\"", cursor: 15))
    shell.send(.ping)
    try shell.wait("ghost on the empty line") { if case .state(_, _, "", "git commit -m \"\"") = $0 { true } else { false } }
    shell.type("\u{1b}[C")
    try shell.waitLine("git commit -m \"\"")
    #expect(shell.lastLine?.cursor == 15)
  }

  @Test func zshAutosuggestionsKeepsItsGhostText() throws {
    // A stand-in for zsh-autosuggestions: the plugin only looks for its start function.
    let shell = try PluginShell(zshrc: "_zsh_autosuggest_start() { }")
    defer { shell.stop() }
    let hello = try shell.start(features: ["ghost"])
    #expect(hello.plugins.contains("zsh-autosuggestions"))
    #expect(!hello.keys.contains("right"))
  }

  // MARK: - S5: asking Claude from a # line

  @Test func hashLinesAskClaudeOnTabAndEnter() throws {
    let shell = try PluginShell()
    defer { shell.stop() }
    let hello = try shell.start(features: ["tab", "claude"])
    #expect(hello.keys.contains("enter"))
    shell.type("# list big files")
    try shell.waitLine("# list big files")
    shell.clear()
    shell.type("\t")
    try shell.wait("open ask on Tab") { if case .open(.ask, _) = $0 { true } else { false } }
    shell.clear()
    shell.type("\r")
    try shell.wait("open ask on ⏎") { if case .open(.ask, _) = $0 { true } else { false } }
    // Nothing ran.
    #expect(!shell.events.contains { if case .exec = $0 { true } else { false } })
  }

  @Test func enterOnASentenceAsksStudioToTranslateIt() throws {
    let shell = try PluginShell()
    defer { shell.stop() }
    try shell.start(features: ["claude"])
    shell.type("create a directory")
    try shell.waitLine("create a directory")
    shell.clear()
    shell.type("\r")
    try shell.wait("open translate on ⏎") { if case .open(.translate, _) = $0 { true } else { false } }
    // Nothing ran.
    #expect(!shell.events.contains { if case .exec = $0 { true } else { false } })
    // A command word still runs at once.
    shell.type("\u{15}")
    shell.clear()
    shell.type("echo sentence-$((2*2)) and more\r")
    try shell.waitScreen("sentence-4 and more")
  }

  @Test func enterRunsEverythingElseAsBefore() throws {
    let shell = try PluginShell()
    defer { shell.stop() }
    try shell.start(features: ["claude"])
    shell.type("echo plain-$((3*3))\r")
    try shell.waitScreen("plain-9")
    shell.clear()
    // With Claude off, a # line is just a comment to zsh.
    shell.send(.config(features: ["tab"]))
    Thread.sleep(forTimeInterval: 0.2)
    shell.type("# a note\r")
    try shell.wait("the # line ran") { if case .exec(_, _, "# a note") = $0 { true } else { false } }
  }
}
