import Combine
import Foundation
import GlanceCore
import GlanceKit

/// `glance automation <list | approve | trust | enable | save | history | restore | delete>` (spec
/// 2026-10-09-automations-design.md, stages A1 and A2): the library from the command line, for scripts and for
/// checking the engine without Studio. Every command takes `--library <dir>` (default: Glance's own library).
enum AutomationEngineCommands {
  static let usage = """
    usage: glance automation <command> [--library <dir>]
      check <id|path> [--inputs <json>]
      list
      approve <id>
      trust <id> on|off
      enable <id> on|off
      save <id> --from <folder>
      history <id>
      restore <id> <commit>
      delete <id>
      plugin [--into <folder>]
      mcp [--socket <path>]
      run <id> [--inputs <json>] [--approve-outward]
      serve [--for <seconds>] [--approve-outward] [--event <name> <payload json>] [--socket <path>]
    """

  static func run(_ arguments: [String]) -> Int32 {
    var rest = arguments
    var library = AutomationLibrary.standard
    if let flag = rest.firstIndex(of: "--library") {
      guard flag + 1 < rest.count else {
        print(usage)
        return 2
      }
      library = AutomationLibrary(root: URL(fileURLWithPath: (rest[flag + 1] as NSString).expandingTildeInPath))
      rest.removeSubrange(flag...(flag + 1))
    }
    guard let command = rest.first else {
      print(usage)
      return 2
    }
    let args = Array(rest.dropFirst())
    switch (command, args.count) {
    case ("list", 0): return list(library)
    case ("approve", 1): return approve(library, args[0])
    case ("trust", 2), ("enable", 2): return toggle(library, command, id: args[0], args[1])
    case ("save", 3) where args[1] == "--from": return save(library, args[0], from: args[2])
    case ("history", 1): return history(library, args[0])
    case ("restore", 2): return restore(library, args[0], commit: args[1])
    case ("delete", 1): return delete(library, args[0])
    case ("run", 1...): return MainActor.assumeIsolated { runOnce(library, args) }
    case ("serve", _): return MainActor.assumeIsolated { serve(library, args) }
    case ("plugin", _): return plugin(args)
    case ("mcp", _): return AutomationMCPCommand.run(library, args)
    default:
      print(usage)
      return 2
    }
  }

  /// One line each: "hello v2 approved", "fix-red-ci v3 needs approval off trusted", "old broken: id: …".
  static func list(_ library: AutomationLibrary) -> Int32 {
    let approvals = library.loadApprovals()
    let calls = library.calls()
    for id in library.ids() {
      let loaded = library.load(id, calls: calls)
      guard let manifest = loaded.manifest, loaded.problems.isEmpty else {
        print("\(id) broken: \(loaded.problems.first?.description ?? "automation.json doesn't read")")
        continue
      }
      let record = approvals.record(id)
      let state = switch approvals.status(of: manifest) {
      case .approved: "approved"
      case .changed: "needs approval"
      case .never: "not approved"
      }
      print("\(id) v\(manifest.version) \(state)\(record.enabled ? "" : " off")\(record.trusted ? " trusted" : "")")
    }
    return 0
  }

  /// Prints what approving allows, then approves the version on disk.
  static func approve(_ library: AutomationLibrary, _ id: String) -> Int32 {
    let loaded = library.load(id, calls: library.calls())
    guard let manifest = loaded.manifest, let text = loaded.manifestText, loaded.problems.isEmpty else {
      print(loaded.problems.isEmpty ? "glance: no automation `\(id)`" : AutomationCheck.report(loaded.problems))
      return 1
    }
    var approvals = library.loadApprovals()
    if case .changed(let lines) = approvals.status(of: manifest) { lines.forEach { print("changed: \($0)") } }
    AutomationApproval.summary(manifest).forEach { print($0) }
    approvals.approve(manifest, manifestText: text)
    guard library.saveApprovals(approvals) else { return approvalsFailed(library) }
    print("approved \(id) v\(manifest.version)")
    return 0
  }

  static func approvalsFailed(_ library: AutomationLibrary) -> Int32 {
    print("glance: couldn't write \(library.root.path)/\(AutomationApprovalBook.fileName)")
    return 1
  }

  static func toggle(_ library: AutomationLibrary, _ command: String, id: String, _ value: String) -> Int32 {
    guard ["on", "off"].contains(value), library.ids().contains(id) else {
      print(library.ids().contains(id) ? usage : "glance: no automation `\(id)`")
      return 2
    }
    var approvals = library.loadApprovals()
    if command == "trust" { approvals.setTrusted(id, value == "on") } else { approvals.setEnabled(id, value == "on") }
    guard library.saveApprovals(approvals) else { return approvalsFailed(library) }
    print("\(id) \(command == "trust" ? "trusted" : "enabled"): \(value)")
    return 0
  }

  static func save(_ library: AutomationLibrary, _ id: String, from folder: String) -> Int32 {
    let files = AutomationLibrary.readFiles(URL(fileURLWithPath: (folder as NSString).expandingTildeInPath))
    guard !files.isEmpty else {
      print("glance: nothing to save in \(folder)")
      return 2
    }
    switch library.save(id, files: files) {
    case .success(let saved):
      let commit = saved.commit.map { " (\($0.prefix(7)))" } ?? " (no history: git isn't installed)"
      print("saved \(id) v\(saved.version)\(commit)")
      return 0
    case .failure(let error):
      print(error.message)
      return 1
    }
  }

  static func history(_ library: AutomationLibrary, _ id: String) -> Int32 {
    switch library.history(id) {
    case .needsGit:
      print(AutomationHistory.needsGitMessage)
      return 1
    case .entries(let entries):
      let stamp = Date.ISO8601FormatStyle()
      entries.forEach { print("\($0.shortCommit) \(stamp.format($0.date)) \($0.message)") }
      return 0
    }
  }

  static func restore(_ library: AutomationLibrary, _ id: String, commit: String) -> Int32 {
    switch library.restore(id, commit: commit) {
    case .success(let saved):
      print("restored \(id) as v\(saved.version)")
      return 0
    case .failure(let error):
      print(error.message)
      return 1
    }
  }

  static func delete(_ library: AutomationLibrary, _ id: String) -> Int32 {
    switch library.delete(id) {
    case .success:
      var approvals = library.loadApprovals()
      approvals.remove(id)
      guard library.saveApprovals(approvals) else {
        print("deleted \(id), but its approval row stayed")
        return approvalsFailed(library)
      }
      print("deleted \(id)")
      return 0
    case .failure(let error):
      print(error.message)
      return 1
    }
  }

  // MARK: The engine

  /// Pulls a flag such as `--approve-outward` out of the arguments: true when it was there.
  static func takeFlag(_ flag: String, from args: inout [String]) -> Bool {
    guard let index = args.firstIndex(of: flag) else { return false }
    args.remove(at: index)
    return true
  }

  /// Pulls `--name <value>` out of the arguments: nil when absent, "" when the value is missing.
  static func takeValue(_ flag: String, from args: inout [String]) -> String? {
    guard let index = args.firstIndex(of: flag) else { return nil }
    let value = index + 1 < args.count ? args[index + 1] : ""
    args.removeSubrange(index...min(index + 1, args.count - 1))
    return value
  }

  /// Prints the engine's activity, one line each: "<automation> <event summary>" or "<automation> note: <text>".
  @MainActor
  static func printActivity(_ engine: AutomationEngine) -> AnyCancellable {
    setvbuf(stdout, nil, _IOLBF, 0)
    return engine.activity.sink { activity in
      switch activity {
      case .logged(let ref, let event): print("\(ref.automation) \(event.summary)")
      case .note(let id, let text): print("\(id) note: \(text)")
      }
    }
  }

  /// `run <id> [--inputs <json>] [--approve-outward]`: one run, no triggers, every log line printed as it's written.
  /// A parked step without `--approve-outward` cancels the run, and so does an ask step's question. Exit 0 when the run ends ok, 1 otherwise.
  @MainActor
  static func runOnce(_ library: AutomationLibrary, _ arguments: [String]) -> Int32 {
    var args = arguments
    let approve = takeFlag("--approve-outward", from: &args)
    var given: [String: AutomationValue] = [:]
    if let text = takeValue("--inputs", from: &args) {
      guard let object = AutomationValue.decode(Data(text.utf8))?.object else {
        print(#"glance: --inputs needs a JSON object, like '{"repo": "acme/app"}'"#)
        return 2
      }
      given = object
    }
    guard args.count == 1 else {
      print(usage)
      return 2
    }
    let engine = AutomationEngine(library: library)
    engine.postsNotices = false
    engine.approvesOutward = approve
    var ends: [AutomationRunRef: RunRecord.Status] = [:]
    var parked: [AutomationRunRef] = []
    var asked: [AutomationRunRef] = []
    let printing = printActivity(engine)
    let watching = engine.activity.sink { activity in
      guard case .logged(let ref, let event) = activity else { return }
      if case .runEnd(let status) = event { ends[ref] = status }
      if case .runPark = event, !approve { parked.append(ref) }
      if case .runAsk = event { asked.append(ref) }
    }
    engine.start(triggers: false)
    let target: AutomationRunRef
    switch engine.run(args[0], inputs: given) {
    case .started(let ref): target = ref
    case .queued: return 1
    case .refused(let reason):
      print(reason)
      return 1
    }
    while ends[target] == nil {
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
      for ref in parked {
        print("\(ref.automation) waiting for approval; pass --approve-outward to approve outward steps")
        engine.cancel(ref)
      }
      parked.removeAll()
      for ref in asked {
        print("\(ref.automation) is asking you a question; questions are answered in Glance Studio")
        engine.cancel(ref)
      }
      asked.removeAll()
    }
    withExtendedLifetime((printing, watching)) {}
    engine.stop()
    return ends[target] == .ok ? 0 : 1
  }

  final class SignalFlag: @unchecked Sendable {
    private(set) var raised = false
    func raise() { raised = true }
  }

  /// `serve [--for <seconds>] [--approve-outward] [--event <name> <payload json>] [--socket <path>]`: the engine with the armed
  /// automations' triggers, printing fires, notes and log lines until the time is up (default: until Ctrl-C). Runs
  /// still going at the end are cancelled. `--event` publishes one Glance event 2 s in.
  @MainActor
  static func serve(_ library: AutomationLibrary, _ arguments: [String]) -> Int32 {
    var args = arguments
    let approve = takeFlag("--approve-outward", from: &args)
    let socketPath = takeValue("--socket", from: &args)
    var seconds: TimeInterval?
    if let text = takeValue("--for", from: &args) {
      guard let value = TimeInterval(text), value > 0 else {
        print(usage)
        return 2
      }
      seconds = value
    }
    var event: GlanceEvent?
    if let index = args.firstIndex(of: "--event") {
      guard index + 2 < args.count, let payload = AutomationValue.decode(Data(args[index + 2].utf8)),
            payload.object != nil else {
        print(usage)
        return 2
      }
      event = GlanceEvent(name: args[index + 1], payload: payload)
      args.removeSubrange(index...(index + 2))
    }
    guard args.isEmpty else {
      print(usage)
      return 2
    }
    let engine = AutomationEngine(library: library)
    engine.postsNotices = false
    engine.approvesOutward = approve
    let printing = printActivity(engine)
    engine.start(triggers: true)
    // The Glance MCP's way in, so `glance automation mcp --socket <path>` can be checked without Studio.
    var socket: AutomationSocketServer?
    if let socketPath {
      let server = AutomationSocketServer(engine: engine, path: socketPath)
      if let problem = server.start() {
        print("glance: \(problem)")
        engine.stop()
        return 1
      }
      socket = server
      print("listening at \(socketPath)")
    }
    let armed = engine.entries.filter(\.armed).map(\.id)
    print("serving \(library.root.path): " + (armed.isEmpty ? "nothing armed" : armed.joined(separator: ", ")))
    if let event {
      // What a Glance feature would publish, 2 s in (event triggers can be checked without Studio).
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        MainActor.assumeIsolated {
          print("publishing \(event.name) \(event.payload.json)")
          GlanceEventBus.shared.publish(event)
        }
      }
    }
    // Ctrl-C or a kill must still end the watchers' process groups: catch the signals and fall through to stop().
    let interrupted = SignalFlag()
    let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
      source.setEventHandler { interrupted.raise() }
      source.resume()
      return source
    }
    let end = seconds.map { Date().addingTimeInterval($0) } ?? .distantFuture
    while Date() < end, !interrupted.raised {
      RunLoop.main.run(mode: .default, before: min(end, Date().addingTimeInterval(0.5)))
    }
    signals.forEach { $0.cancel() }
    if interrupted.raised { print("stopping") }
    socket?.stop()
    engine.stop()
    let deadline = Date().addingTimeInterval(5)
    while !engine.live.isEmpty, Date() < deadline {
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    withExtendedLifetime(printing) {}
    return 0
  }

  /// `plugin [--into <folder>]`: writes Glance's Claude plugin (the skill and the Glance MCP, with this glance as its
  /// server) where Studio keeps it, or into `folder`, and prints the folder. Studio writes it itself at launch; this is
  /// for checking it and for using it without Studio (`claude --plugin-dir <folder>`).
  static func plugin(_ arguments: [String]) -> Int32 {
    var folder = ClaudePluginDir.standard
    let cli = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
    switch arguments.count {
    case 0:
      // Studio's own folder is pointed at the glance that wrote it: only the installed app may do that.
      guard AutomationPlugin.isInsideAppBundle(cli) else {
        print("glance: this glance isn't inside an app, so it won't rewrite Studio's plugin folder; use --into <folder>")
        return 1
      }
    case 2 where arguments[0] == "--into":
      folder = URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath, isDirectory: true)
    default:
      print(usage)
      return 2
    }
    guard ClaudePluginDir.isUsable(folder) else {
      print("glance: \(folder.path) isn't a Glance plugin folder; choose an empty or new folder")
      return 1
    }
    guard let written = ClaudePluginDir.install(cli: cli, at: folder) else {
      print("glance: couldn't write the plugin to \(folder.path)")
      return 1
    }
    print(written.path)
    return 0
  }
}
