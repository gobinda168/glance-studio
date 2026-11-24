import Foundation

/// What a tracking hook prints: a note for Claude as additional context, or nothing.
public struct HookReply: Equatable, Sendable {
  public var context: String?
  public static let none = HookReply(context: nil)

  public init(context: String?) {
    self.context = context
  }

  /// Claude Code's hook JSON carrying the note, or nil (print nothing).
  public func output(event: String) -> String? {
    guard let context, !context.isEmpty else { return nil }
    let object: [String: Any] = ["hookSpecificOutput": ["hookEventName": event, "additionalContext": context]]
    return (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) }
  }
}

/// `glance track <event>`'s work (spec §1–2): fingerprints the worktree, then under the repository's lock records
/// what changed and who made it, keeps the sessions, and returns any note for Claude. Folders outside git and tools
/// that change no files are ignored.
public struct ChangeTracker {
  /// Tools that never change files: their calls are skipped, with no git and no lock. A subagent's own tool calls come
  /// with its parent's session id, so the Task or Agent call around them is skipped too.
  public static let readOnlyTools: Set<String> = ["Read", "Grep", "Glob", "LS", "WebFetch", "WebSearch", "TodoWrite",
                                                  "Task", "Agent", "NotebookRead"]

  public var ledger: Ledger
  public var now: () -> Date
  /// The `claude` process the hook runs under.
  public var claudePID: Int32?
  /// "studio:<surface id>" in a Glance Studio shell, else the terminal app.
  public var terminal: String?
  public var alive: (Int32) -> Bool
  public var location: (String) -> RepoLocation?
  public var fingerprint: (String, Fingerprint?) -> Fingerprint?
  /// Proof of work without Worktrees (`Feature.commandCenter` alone): the live session list is kept, but nothing is
  /// fingerprinted and Claude is told nothing.
  public var sessionsOnly = false

  public init(ledger: Ledger = Ledger(), now: @escaping () -> Date = Date.init, claudePID: Int32? = nil,
              terminal: String? = nil, alive: @escaping (Int32) -> Bool = ProcessTree.isClaude,
              location: @escaping (String) -> RepoLocation? = RepoLocation.find(cwd:),
              fingerprint: @escaping (String, Fingerprint?) -> Fingerprint? = Fingerprint.current(root:previous:)) {
    self.ledger = ledger
    self.now = now
    self.claudePID = claudePID
    self.terminal = terminal
    self.alive = alive
    self.location = location
    self.fingerprint = fingerprint
  }

  public func handle(_ input: HookInput) -> HookReply {
    // Claude Code reports a failed tool call as PostToolUseFailure; for change tracking it ends the call the same way.
    var input = input
    if input.event == "PostToolUseFailure" { input.event = "PostToolUse" }
    if sessionsOnly, input.event == "PreToolUse" || input.event == "PostToolUse" { return .none }
    if input.event == "PreToolUse" || input.event == "PostToolUse", let tool = input.toolName,
       Self.readOnlyTools.contains(tool) {
      return .none
    }
    guard let place = location(input.cwd) else { return .none }
    // git runs before the lock, so parallel hooks don't queue behind each other's git. The state file is written
    // atomically: this unlocked read only feeds the hash cache and says where a finishing call ran.
    let look = sessionsOnly ? nil : self.look(input, place: place, state: ledger.state(repo: place.commonDir))
    return ledger.locked(repo: place.commonDir) { () -> HookReply in
      var state = ledger.state(repo: place.commonDir)
      let time = now()
      var records: [LedgerRecord] = []
      record(input, place: place, look: look, time: time, state: &state, records: &records)
      ledger.append(records, repo: place.commonDir)
      if state.pruned.map({ time.timeIntervalSince($0) > 86_400 }) ?? true {
        let cutoff = time.addingTimeInterval(-30 * 86_400)
        ledger.prune(repo: place.commonDir, before: cutoff)
        // This worktree exists: git just found it.
        state.prune(before: cutoff, alive: alive,
                    exists: { $0 == place.worktree || FileManager.default.fileExists(atPath: $0) })
        state.pruned = time
      }
      let note = sessionsOnly ? nil : notes(input, tree: place.worktree, state: &state)
      ledger.save(state)
      return HookReply(context: note)
    } ?? .none
  }

  /// A worktree's fingerprint, taken before the lock, and when that look began.
  struct Look {
    var tree: String
    var print: Fingerprint
    var at: Date
  }

  /// The fingerprint `input`'s event needs: of the hook's worktree, or for a PostToolUse of the worktree its call
  /// started in. Nil when the event needs none (or the call isn't open) or git failed.
  func look(_ input: HookInput, place: RepoLocation, state: TrackState) -> Look? {
    let tree: String
    switch input.event {
    case "SessionStart", "UserPromptSubmit":
      tree = place.worktree
    case "PreToolUse":
      guard input.toolUseID != nil else { return nil }
      tree = place.worktree
    case "PostToolUse":
      guard let id = input.toolUseID, let call = state.open[id] else { return nil }
      tree = call.worktree
    default:
      return nil
    }
    let at = now()
    return fingerprint(tree, state.fingerprints[tree]).map { Look(tree: tree, print: $0, at: at) }
  }

  func record(_ input: HookInput, place: RepoLocation, look: Look?, time: Date, state: inout TrackState,
              records: inout [LedgerRecord]) {
    let tree = place.worktree
    // A call whose PostToolUse never came (Claude quit mid-call) stops counting after ten minutes.
    state.open = state.open.filter { time.timeIntervalSince($0.value.started) < 600 }
    func add(_ record: LedgerRecord) {
      records.append(record)
      state.apply(record)
    }
    switch input.event {
    case "SessionStart":
      add(LedgerRecord(t: time, kind: .sessionStart, worktree: tree, session: input.sessionID, branch: place.branch,
                       pid: claudePID, terminal: terminal))
      if let look, let outside = lookOutside(look, branch: place.branch, time: time, state: &state).outside {
        add(outside)
      }
    case "UserPromptSubmit":
      if state.sessions[input.sessionID]?.task == nil, let prompt = input.prompt {
        if state.sessions[input.sessionID] == nil {
          // A session started before tracking was on: known from its first prompt.
          add(LedgerRecord(t: time, kind: .sessionStart, worktree: tree, session: input.sessionID,
                           branch: place.branch, pid: claudePID, terminal: terminal))
        }
        add(LedgerRecord(t: time, kind: .prompt, worktree: tree, session: input.sessionID,
                         text: String(prompt.prefix(200))))
      }
      if let look, let outside = lookOutside(look, branch: place.branch, time: time, state: &state).outside {
        add(outside)
      }
    case "PreToolUse":
      guard let id = input.toolUseID, let look else { return }
      let looked = lookOutside(look, branch: place.branch, time: time, state: &state)
      let now = looked.print
      if let outside = looked.outside { add(outside) }
      var call = TrackState.OpenCall(session: input.sessionID, worktree: tree,
                                     hashes: now.tooMany ? nil : now.hashes, started: time)
      for (key, other) in state.open where other.worktree == tree && other.session != input.sessionID {
        call.overlapped.append(other.session)
        state.open[key]?.overlapped.append(input.sessionID)
      }
      state.open[id] = call
    case "PostToolUse":
      guard let id = input.toolUseID, let call = state.open.removeValue(forKey: id), let look,
            look.tree == call.worktree else { return }
      let after = look.print
      if let change = ChangeAttribution.call(call, tool: input.toolName, after: after, branch: place.branch, at: time) {
        add(change)
      }
      state.setFingerprint(after, for: call.worktree, at: look.at)
    case "SessionEnd":
      add(LedgerRecord(t: time, kind: .sessionEnd, worktree: tree, session: input.sessionID))
      state.open = state.open.filter { $0.value.session != input.sessionID }
    default:
      break
    }
  }

  /// Works out from `look` what changed outside Claude since the last look, and remembers its fingerprint. When a
  /// look that began later was stored meanwhile (by a hook that took the lock first), that one is newer and already
  /// accounts for everything up to `look`: it is kept, nothing is recorded, and it is the `print` returned.
  /// `outside` is the record for the caller to append and apply.
  func lookOutside(_ look: Look, branch: String?, time: Date,
                   state: inout TrackState) -> (print: Fingerprint, outside: LedgerRecord?) {
    let tree = look.tree
    if let newer = state.fingerprints[tree], let at = state.looked[tree], at > look.at.timeIntervalSince1970 { return (newer, nil) }
    let open = state.open.values.filter { $0.worktree == tree }
    let outside = ChangeAttribution.outside(last: state.fingerprints[tree], now: look.print, openThere: Array(open),
                                            worktree: tree, branch: branch, at: time)
    state.setFingerprint(look.print, for: tree, at: look.at)
    return (look.print, outside)
  }

  /// The note for Claude after this event, if any; `state.told` is updated so a warning isn't repeated.
  func notes(_ input: HookInput, tree: String, state: inout TrackState) -> String? {
    guard let print = state.fingerprints[tree] else { return nil }
    let sessions = state.sessions
    let context = WorktreeWarnings.Context(
      me: input.sessionID,
      // Too many files: the stored entries are an old look, so no file is named.
      files: print.tooMany ? [] : Uncommitted.attribute(print, authors: state.authors[tree] ?? [:]),
      live: sessions.values.filter { $0.worktree == tree && $0.isLive(alive) }.sorted { $0.started < $1.started },
      name: { SessionName.of($0, task: sessions[$0]?.task) })
    let firstPrompt = input.event == "UserPromptSubmit" && state.told[input.sessionID]?["prompted"] == nil
    var candidates: [WorktreeWarning?] = []
    var always = false
    switch input.event {
    case "SessionStart":
      candidates = [WorktreeWarnings.foreignEdits(context), WorktreeWarnings.sharedWorktree(context)]
    case "UserPromptSubmit":
      candidates = [WorktreeWarnings.sharedWorktree(context)]
      if firstPrompt { candidates += [WorktreeWarnings.foreignEdits(context), WorktreeWarnings.topics(context)] }
    case "PostToolUse":
      candidates = [WorktreeWarnings.foreignEdits(context)]
    case "PreToolUse" where WorktreeWarnings.isCommit(input.command):
      // Nothing to warn about when every file is this session's and no other session works here.
      let onlyMine = context.files.allSatisfy { $0.author == .session(input.sessionID) }
        && context.live.allSatisfy { $0.id == input.sessionID }
      candidates = onlyMine ? [] : [WorktreeWarnings.topics(context)]
      always = true
    default:
      break
    }
    var told = state.told[input.sessionID] ?? [:]
    if firstPrompt { told["prompted"] = ["yes"] }
    let warnings = always ? candidates.compactMap { $0 } : WorktreeWarnings.unseen(candidates.compactMap { $0 }, told: &told)
    state.told[input.sessionID] = told
    return warnings.isEmpty ? nil : warnings.map(\.text).joined(separator: "\n\n")
  }
}
