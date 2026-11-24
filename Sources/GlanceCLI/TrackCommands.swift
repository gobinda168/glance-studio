import Darwin
import Foundation
import GlanceCore
import GlanceKit

/// `glance track <Event>` (a Claude Code hook: never fails, never blocks), `glance changes` and `glance track-hooks`.
enum TrackCommands {
  static func track(_ arguments: [String]) -> Int32 {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard var input = HookInput.parse(data) else { return 0 }
    if let event = arguments.first(where: { !$0.hasPrefix("--") }) { input.event = event }
    let env = ProcessInfo.processInfo.environment
    let terminal = env["GLANCE_SURFACE_ID"].map { "studio:" + $0 } ?? env["TERM_PROGRAM"]
    // Proof first: a slow fingerprint or a busy ledger below must not use up the hook's time and lose it.
    // Studio writes --work into the wrapper script. Never prints, never fails.
    if arguments.contains("--work"), input.event == "PostToolUse" || input.event == "PostToolUseFailure" {
      WorkObserver().observe(data)
    }
    var tracker = ChangeTracker(claudePID: ProcessTree.claudeAncestor(of: getpid()), terminal: terminal)
    tracker.sessionsOnly = arguments.contains("--sessions-only")
    if let output = tracker.handle(input).output(event: input.event) { print(output) }
    return 0
  }

  /// `glance changes [--mine | --session <id>] [--json] [--cwd <path>]`: the worktree's uncommitted files with who
  /// made each; `--mine` keeps this session's (found through the `claude` process this command runs under).
  static func changes(_ arguments: [String]) -> Int32 {
    func value(_ flag: String) -> String? {
      arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }
    let cwd = value("--cwd") ?? FileManager.default.currentDirectoryPath
    guard let place = RepoLocation.find(cwd: cwd) else {
      FileHandle.standardError.write(Data("glance: \(cwd) isn't in a git repository with a commit\n".utf8))
      return 1
    }
    let ledger = Ledger()
    let state = ledger.state(repo: place.commonDir)
    let now = Fingerprint.current(root: place.worktree, previous: state.fingerprints[place.worktree]) ?? Fingerprint()
    var files = Uncommitted.attribute(now, authors: state.authors[place.worktree] ?? [:])
    var session = value("--session")
    if arguments.contains("--mine") {
      let claude = ProcessTree.claudeAncestor(of: getpid())
      session = state.liveSession(claudePID: claude)
      guard session != nil else {
        FileHandle.standardError.write(Data("glance: no tracked Claude session runs this command\n".utf8))
        return 1
      }
    }
    if let session { files = files.filter { $0.author == .session(session) } }
    if arguments.contains("--json") {
      let rows = files.map { ["path": $0.path, "status": $0.status, "author": describe($0.author, state)] }
      let data = (try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .withoutEscapingSlashes]))
      print(data.map { String(decoding: $0, as: UTF8.self) } ?? "[]")
    } else {
      for file in files { print("\(file.status)\t\(file.path)\t\(describe(file.author, state))") }
    }
    return 0
  }

  static func describe(_ author: Author, _ state: TrackState) -> String {
    switch author {
    case .session(let id): SessionName.of(id, task: state.sessions[id]?.task)
    case .outside: "outside Claude"
    case .ambiguous(let ids): "ambiguous: " + ids.map { SessionName.of($0, task: state.sessions[$0]?.task) }.joined(separator: ", ")
    }
  }

  /// `glance track-hooks install [--changes] [--work] | uninstall | status`. Install keeps the flags of the script already
  /// installed (Studio chose them) unless `--changes` or `--work` say otherwise; with none installed it tracks changes.
  static func hooks(_ arguments: [String]) -> Int32 {
    switch arguments.first {
    case "install", "uninstall":
      // The running binary's real path (argv[0] may be a bare name found on PATH). Removing doesn't need it.
      let glance = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? ""
      if arguments.first == "install", !FileManager.default.isExecutableFile(atPath: glance) {
        FileHandle.standardError.write(Data("glance: couldn't find the running glance binary, so no hooks were installed.\n".utf8))
        return 1
      }
      do {
        var options: TrackHookSetup.Options = []
        if arguments.contains("--changes") { options.insert(.changes) }
        if arguments.contains("--work") { options.insert(.work) }
        if options.isEmpty { options = TrackHooks.installedOptions() ?? [.changes] }
        try TrackHooks.set(on: arguments.first == "install", glance: glance, options: options)
        print(arguments.first == "install" ? "Tracking hooks installed (\(glance))." : "Tracking hooks removed.")
        return 0
      } catch {
        print("glance: \(error.localizedDescription)")
        return 1
      }
    case "status":
      print(TrackHooks.isOn() ? "installed" : "not installed")
      return 0
    default:
      print("usage: glance track-hooks install [--changes] [--work] | uninstall | status")
      return 2
    }
  }
}

extension TrackCommands {
  /// `glance worktree new --task <name> [--cwd <path>]` and `glance worktree move --mine --task <name>`: the
  /// worktree fixes Claude offers (spec §2). Prints the new folder and how to continue there.
  static func worktree(_ arguments: [String]) -> Int32 {
    func value(_ flag: String) -> String? {
      arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }
    guard let task = value("--task"), !task.isEmpty else {
      print("usage: glance worktree new|move --task <name> [--mine] [--cwd <path>]")
      return 2
    }
    let cwd = value("--cwd") ?? FileManager.default.currentDirectoryPath
    guard let place = RepoLocation.find(cwd: cwd) else {
      print("glance: \(cwd) isn't in a git repository with a commit")
      return 1
    }
    switch arguments.first {
    case "new":
      // From a linked worktree the new folder still sits beside the main one: ../<repo>-<slug>.
      let main = place.commonDir.hasSuffix("/.git") ? URL(fileURLWithPath: place.commonDir).deletingLastPathComponent().path : place.worktree
      switch WorktreeActions.create(repoRoot: main, task: task, from: nil) {
      case .success(let made):
        print("Created \(made.path) on branch \(made.branch).\nStart there: cd '\(made.path)' && claude")
        return 0
      case .failure(let failure):
        print("glance: \(failure.message)")
        return 1
      }
    case "move":
      guard arguments.contains("--mine") else {
        print("glance: move needs --mine (it moves this session's files only)")
        return 2
      }
      let state = Ledger().state(repo: place.commonDir)
      let claude = ProcessTree.claudeAncestor(of: getpid())
      guard let session = state.liveSession(claudePID: claude) else {
        print("glance: no tracked Claude session runs this command")
        return 1
      }
      let now = Fingerprint.current(root: place.worktree, previous: state.fingerprints[place.worktree]) ?? Fingerprint()
      let mine = Uncommitted.attribute(now, authors: state.authors[place.worktree] ?? [:])
        .filter { $0.author == .session(session) }
      guard !mine.isEmpty else {
        print("glance: this session has no uncommitted files here")
        return 1
      }
      switch WorktreeActions.move(files: mine, from: place.worktree, task: task) {
      case .success(let made):
        print("Moved \(mine.count) files to \(made.path) (branch \(made.branch)); they're restored here.")
        print("Continue there: cd '\(made.path)' && claude --resume \(session)")
        return 0
      case .failure(let failure):
        print("glance: \(failure.message)")
        return 1
      }
    default:
      print("usage: glance worktree new|move --task <name> [--mine] [--cwd <path>]")
      return 2
    }
  }
}
