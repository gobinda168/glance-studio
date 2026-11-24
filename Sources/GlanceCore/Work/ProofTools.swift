import Foundation

/// The proof tools on Glance's MCP server (spec §3 "Claude says"), answered by the `glance mcp` shim itself, so proof
/// works with Studio closed. They write the session's `WorkRecord` (notes, pending items, the verdict, captures with
/// a purpose) and read the project's setup. A tool's failure is a sentence Claude can act on, never a crash.
public enum ProofTools {
  public struct Failure: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
  }

  public static let names: Set<String> = ["proof_note", "proof_pending", "proof_verdict", "proof_capture", "proof_setup"]
  /// How long a write waits for the record's lock: the shim runs these off its own queue, so it can wait.
  static let lockBudget: TimeInterval = 2

  public static let definitions: [JSONValue] = [
    ChannelTools.tool("proof_note", "Record something about this session's work in Glance's proof: what you tried, "
      + "what you found, a problem, or how one was resolved. Shown to the user as \"Claude says\".",
      ["kind": enumeration(["tried", "found", "problem", "resolved"], "What this is: tried, found, a problem, or resolved."), "text": ChannelTools.string("One or two sentences."),
       "section": ChannelTools.string("Optional: one of the project setup's sections (from proof_setup).")],
      required: ["kind", "text"]),
    ChannelTools.tool("proof_pending", "Add an item that still has to be done, or tick one off (same text, done: true).",
      ["text": ChannelTools.string("The item."), "done": ChannelTools.boolean("True to tick it off.")], required: ["text"]),
    ChannelTools.tool("proof_verdict", "Say whether this work should merge, with the reasons. Call it once, at the end of "
      + "the work (a later call replaces the earlier one). Glance shows it beside the checks it saw run; a claim "
      + "without a matching check is flagged.",
      ["verdict": enumeration(["merge", "hold", "not-ready"], "merge, hold or not-ready."), "reasons": ChannelTools.strings("Why, one reason each.")],
      required: ["verdict", "reasons"]),
    ChannelTools.tool("proof_capture", "Add a file to this session's proof: a screenshot (png, jpg, jpeg, gif, webp, "
      + "heic), a video (mp4, mov, webm, m4v) or a log (log, txt); other files are refused. Use purpose \"outcome\" "
      + "only for a screenshot or clip of the final result the user should see first; every other capture is a "
      + "testing one (\"test\", the default).",
      ["path": ChannelTools.string("The file. Prefer an absolute path; a relative one is resolved from this "
                                   + "session's working directory (the folder Claude Code was started in)."),
       "caption": ChannelTools.string("What it shows."), "url": ChannelTools.string("The page it shows, if any."),
       "purpose": enumeration(["test", "outcome"], "test (default) or outcome.")], required: ["path", "caption"]),
    ChannelTools.tool("proof_setup", "This project's proof setup (.glance/proof.json): its environments, checks, what "
      + "must pass, and any problems with the file. Read it before running checks.", [:], required: []),
  ]

  private static func enumeration(_ values: [String], _ description: String) -> JSONValue {
    ["type": "string", "enum": .array(values.map(JSONValue.string)), "description": .string(description)]
  }

  /// The most characters kept of any text argument: every hook re-reads the whole record, so it stays small.
  static let textLimit = 4_000
  private static func clip(_ text: String) -> String { String(text.prefix(textLimit)) }
  private static func clip(_ text: String?) -> String? { text.map(clip) }

  // MARK: - Which session

  /// The live Claude session `claudePID` runs in `cwd`'s repository, from the tracking ledger. Never a guess: a missing
  /// process, a folder outside git, or a process the ledger doesn't know is a failure that says which.
  public static func resolveSession(claudePID: Int32?, cwd: String,
                                    location: (String) -> RepoLocation? = RepoLocation.find(cwd:),
                                    ledger: Ledger = Ledger(),
                                    alive: (Int32) -> Bool = ProcessTree.isClaude) -> Result<String, Failure> {
    let lead = "Glance can't tell which session this is"
    guard let claudePID else { return .failure(Failure("\(lead): no claude process found above this tool.")) }
    guard let place = location(cwd) else { return .failure(Failure("\(lead): \(cwd) isn't in a git repository.")) }
    guard let session = ledger.state(repo: place.commonDir).liveSession(claudePID: claudePID, alive: alive) else {
      return .failure(Failure("\(lead): this claude process isn't tracked. Is Command Center on in Glance Studio?"))
    }
    return .success(session)
  }

  // MARK: - MCP framing

  /// The MCP `tools/call` reply line for a proof tool: resolves the session, runs the tool, and wraps the answer as
  /// the shim wraps every tool result, so a failure of either is a tool error and the shim keeps running.
  public static func reply(id: JSONValue, name: String, arguments: JSONValue, claudePID: Int32?, cwd: String,
                           location: (String) -> RepoLocation? = RepoLocation.find(cwd:), ledger: Ledger = Ledger(),
                           alive: (Int32) -> Bool = ProcessTree.isClaude, store: WorkStore = WorkStore(),
                           now: Date = Date()) -> String {
    switch resolveSession(claudePID: claudePID, cwd: cwd, location: location, ledger: ledger, alive: alive) {
    case .failure(let failure):
      return MCP.result(id: id, MCP.toolResult(.string(failure.message), isError: true))
    case .success(let session):
      let (value, isError) = run(name: name, arguments: arguments, session: session, cwd: cwd, store: store, now: now)
      return MCP.result(id: id, MCP.toolResult(value, isError: isError))
    }
  }

  // MARK: - The tools

  public static func run(name: String, arguments: JSONValue, session: String, cwd: String,
                         store: WorkStore = WorkStore(), now: Date = Date()) -> (JSONValue, isError: Bool) {
    let args = ChannelTools.Arguments(arguments)
    do {
      switch name {
      case "proof_setup":
        return (describe(ProofSetupFile.load(cwd: cwd)), false)
      case "proof_note":
        let raw = try args.text("kind")
        guard let kind = ProofNote.Kind(rawValue: raw) else { throw Failure("kind must be one of tried, found, problem, resolved.") }
        let text = clip(try args.text("text"))
        let section = clip(try args.optionalText("section"))
        try write(store, session, cwd, now) { $0.notes.append(ProofNote(kind: kind, section: section, text: text, at: now)) }
        return (["recorded": true], false)
      case "proof_pending":
        let text = clip(try args.text("text"))
        let done = try args.flag("done", default: false)
        try write(store, session, cwd, now) { record in
          if let i = record.pending.firstIndex(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) {
            record.pending[i].done = done
          } else {
            record.pending.append(ProofPending(text: text, done: done, at: now))
          }
        }
        return (["recorded": true], false)
      case "proof_verdict":
        let raw = try args.text("verdict")
        guard let verdict = ProofVerdict.Verdict(rawValue: raw) else { throw Failure("verdict must be one of merge, hold, not-ready.") }
        let reasons = try args.strings("reasons", max: 20, tooMany: "reasons takes at most 20 entries.").map(clip)
        guard !reasons.isEmpty else { throw Failure("reasons is required: say why.") }
        try write(store, session, cwd, now) { $0.verdict = ProofVerdict(verdict: verdict, reasons: reasons, at: now) }
        return (["recorded": true], false)
      case "proof_capture":
        return try capture(args, session: session, cwd: cwd, store: store, now: now)
      default:
        return (.string("Unknown tool \(name)."), true)
      }
    } catch let failure as Failure {
      return (.string(failure.message), true)
    } catch let failure as ChannelTools.Failure {
      return (.string(failure.message), true)
    } catch {
      return (.string(String(describing: error)), true)
    }
  }

  /// Changes the session's record, filling where it runs (cwd, worktree, branch) the way the hooks do: the PR card
  /// finds a session's proof by branch, so a record made by a note alone must carry it too.
  private static func write(_ store: WorkStore, _ session: String, _ cwd: String, _ now: Date,
                            _ change: (inout WorkRecord) -> Void) throws {
    let worktree = ProjectRoot.find(from: cwd)
    let branch = GitHead.branch(inFolder: cwd)
    let commonDir = GitCommonDir.find(from: cwd)
    let saved = store.update(session: session, now: now, budget: lockBudget) { record in
      record.place(cwd: cwd, worktree: worktree, branch: branch, commonDir: commonDir)
      change(&record)
    }
    guard saved != nil else { throw Failure("Glance couldn't save the proof record; try again.") }
  }

  private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic"]
  private static let clipExtensions: Set<String> = ["mp4", "mov", "webm", "m4v"]
  private static let logExtensions: Set<String> = ["log", "txt"]

  private static func capture(_ args: ChannelTools.Arguments, session: String, cwd: String, store: WorkStore,
                              now: Date) throws -> (JSONValue, isError: Bool) {
    let path = try args.text("path")
    let caption = clip(try args.text("caption"))
    let url = clip(try args.optionalText("url"))
    let purpose = try args.optionalText("purpose").map { raw -> ProofCapture.Purpose in
      guard let purpose = ProofCapture.Purpose(rawValue: raw) else { throw Failure("purpose must be test or outcome.") }
      return purpose
    } ?? .test
    let expanded = path.hasPrefix("~") ? (path as NSString).expandingTildeInPath : path
    let source = expanded.hasPrefix("/") ? expanded : URL(fileURLWithPath: cwd).appendingPathComponent(expanded).standardizedFileURL.path
    // Only media and logs: a capture is kept for 60 days and shown to others, so a stray .env or key must not be one.
    let ext = (source as NSString).pathExtension.lowercased()
    guard imageExtensions.contains(ext) || clipExtensions.contains(ext) || logExtensions.contains(ext) else {
      throw Failure("proof_capture takes a screenshot (png, jpg, jpeg, gif, webp, heic), a video (mp4, mov, webm, m4v) or a log (log, txt), not \((source as NSString).lastPathComponent).")
    }
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: source) else {
      throw Failure("No file at \(source).")
    }
    guard attributes[.type] as? FileAttributeType == .typeRegular else { throw Failure("\(source) isn't a file.") }
    guard (attributes[.size] as? Int ?? 0) <= WorkStore.maxCaptureBytes else {
      throw Failure("The file is over 200 MB; capture a shorter clip.")
    }
    let kind: ProofCapture.Kind = imageExtensions.contains(ext) ? .screenshot : clipExtensions.contains(ext) ? .clip : .file
    let environment = url.flatMap { ProofMatcher.environment(forURL: $0, cwd: cwd) }
    let added = store.addCapture(
      session: session, id: UUID().uuidString, from: URL(fileURLWithPath: source), kind: kind, url: url,
      environment: environment, caption: caption, purpose: purpose, source: .claude, cwd: cwd,
      worktree: ProjectRoot.find(from: cwd), branch: GitHead.branch(inFolder: cwd),
      commonDir: GitCommonDir.find(from: cwd), now: now, budget: lockBudget)
    guard added != nil else { throw Failure("Glance couldn't save \(source) into the proof record; try again.") }
    return (["recorded": true, "kind": .string(kind.rawValue)], false)
  }

  /// proof_setup's answer: status missing / invalid (with the problems) / valid (the parsed setup).
  static func describe(_ load: ProofSetupLoad) -> JSONValue {
    switch load {
    case .missing:
      return ["status": "missing", "hint": "No .glance/proof.json in this repository. The glance-proof-setup skill writes one."]
    case .invalid(let issues, let root):
      return ["status": "invalid", "root": .string(root),
              "problems": .array(issues.map { .string(($0.line.map { "line \($0): " } ?? "") + $0.message) })]
    case .valid(let setup, let root):
      let data = (try? JSONEncoder().encode(setup)) ?? Data("{}".utf8)
      let value = JSONValue.parse(String(decoding: data, as: UTF8.self)) ?? [:]
      return ["status": "valid", "root": .string(root), "setup": value]
    }
  }
}
