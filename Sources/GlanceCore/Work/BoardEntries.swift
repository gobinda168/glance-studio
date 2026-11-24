import Foundation

/// A session the board knows, before its record and live state are read.
public struct BoardEntry: Equatable, Sendable {
  public var id: String
  public var task: String?
  public var project: String
  public var repo: String?
  /// The repository's main checkout: where git runs once the worktree is gone.
  public var main: String?
  public var branch: String?
  public var worktree: String?
  public var cwd: String?
  public var transcript: String?
  public var place: BoardCard.Place
  public var live: Bool
  /// When it ended; for a crash (no end recorded) when it started. Nil while live.
  public var ended: Date?
  public var started: Date
  public var mixed: Bool
}

/// What the app learned off the main thread about a tab whose session the ledger doesn't know (a folder outside git).
/// Links outlive an exited `claude` while the tab stays open, so a link alone is no proof the session is alive.
public struct LinkOnlyFacts: Equatable, Sendable {
  /// A `claude` process is really still running for the session.
  public var running: Bool
  /// When the transcript began.
  public var started: Date
  /// When the transcript was last written: the end time once `claude` has gone.
  public var lastActive: Date
  public init(running: Bool, started: Date, lastActive: Date) {
    self.running = running; self.started = started; self.lastActive = lastActive
  }
}

public enum BoardEntries {
  /// Ended sessions kept on the board, newest first; live ones are never dropped.
  public static let doneKept = 40

  /// Every session on the board, one per id. The ledger says what exists and whether it's alive; links say which Studio
  /// split it's in, and add sessions the ledger can't know (a folder outside git). `waiting`: splits with a prompt.
  /// `linkOnly`: whether each of those is really still running; a session with no facts yet is taken as live.
  public static func merge(trees: [RepoTree], links: [SessionLink], waiting: Set<UUID>,
                           linkOnly: [String: LinkOnlyFacts] = [:]) -> [BoardEntry] {
    let bySession = Dictionary(grouping: links, by: \.sessionID)
    func surface(_ id: String) -> SessionLink? {
      let all = (bySession[id] ?? []).sorted { $0.surface.uuidString < $1.surface.uuidString }
      return all.first { waiting.contains($0.surface) } ?? all.first
    }
    var entries: [String: BoardEntry] = [:]
    func add(_ session: TrackedSession, live: Bool, branch: String?, tree: RepoTree, mixed: Bool) {
      let link = live ? surface(session.id) : nil
      let place: BoardCard.Place = if let link {
        .studio(surface: link.surface)
      } else if live {
        .external(WorktreeWarnings.place(session.terminal))
      } else {
        .nowhere
      }
      entries[session.id] = BoardEntry(id: session.id, task: session.task, project: tree.name, repo: tree.repo, main: tree.main,
                                       branch: session.branch ?? branch, worktree: session.worktree,
                                       cwd: link?.cwd ?? surface(session.id)?.cwd, transcript: surface(session.id)?.transcriptPath,
                                       place: place, live: live, ended: live ? nil : (session.ended ?? session.started),
                                       started: session.started, mixed: live && mixed)
    }
    for tree in trees {
      for worktree in tree.worktrees {
        for session in worktree.sessions {
          add(session, live: worktree.live.contains(session.id), branch: worktree.branch, tree: tree, mixed: worktree.warning)
        }
      }
      for session in tree.orphans { add(session, live: false, branch: nil, tree: tree, mixed: false) }
    }
    for link in links where entries[link.sessionID] == nil {
      guard let chosen = surface(link.sessionID) else { continue }
      let folder = chosen.cwd
      let facts = linkOnly[link.sessionID]
      let running = facts?.running ?? true
      entries[link.sessionID] = BoardEntry(id: link.sessionID, task: nil,
                                           project: folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Claude",
                                           repo: nil, main: nil, branch: nil, worktree: nil, cwd: folder,
                                           transcript: chosen.transcriptPath,
                                           place: running ? .studio(surface: chosen.surface) : .nowhere, live: running,
                                           ended: running ? nil : facts?.lastActive, started: facts?.started ?? .distantPast,
                                           mixed: false)
    }
    let ended = entries.values.filter { !$0.live }
      .sorted { ($0.ended ?? .distantPast, $1.id) > ($1.ended ?? .distantPast, $0.id) }
    return entries.values.filter(\.live).sorted { $0.id < $1.id } + ended.prefix(doneKept)
  }

  /// The splits a reply or an answer for `session` may go to, best first: one with a prompt waiting, then `preferred` (the
  /// card's own split), then the rest by id. Only splits whose link is this session count: a split that was /cleared into
  /// another session is not a way to reach it. The app still checks each is alive and running `claude` before typing.
  public static func targets(session: String, links: [SessionLink], waiting: Set<UUID>, preferred: UUID?) -> [UUID] {
    let all = links.filter { $0.sessionID == session }.map(\.surface).sorted { $0.uuidString < $1.uuidString }
    return all.filter(waiting.contains) + all.filter { $0 == preferred && !waiting.contains($0) }
      + all.filter { $0 != preferred && !waiting.contains($0) }
  }

  /// The links whose session the ledger doesn't know: the ones `merge` needs facts about.
  public static func linkOnly(trees: [RepoTree], links: [SessionLink]) -> [SessionLink] {
    var known = Set<String>()
    for tree in trees {
      for worktree in tree.worktrees { for session in worktree.sessions { known.insert(session.id) } }
      for session in tree.orphans { known.insert(session.id) }
    }
    return links.filter { !known.contains($0.sessionID) }
  }

  /// A session's transcript, from the folders it may have started in: Claude files it under the folder's name.
  public static func transcript(session: String, folders: [String], projects: String,
                                exists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> String? {
    guard WorkStore.isSessionID(session) else { return nil }
    return folders.lazy
      .map { "\(projects)/\(ClaudeProjectFolder.name(for: $0))/\(session).jsonl" }
      .first(where: exists)
  }

  /// Whether a branch can have a PR worth a `gh` call: not a name every repository has, nor one git would read as an option.
  public static func wantsPR(branch: String?) -> Bool {
    guard let branch, !branch.isEmpty, !branch.hasPrefix("-") else { return false }
    return !ProofRecords.sharedBranches.contains(branch)
  }
}

/// `claude --resume <id>` finds a session only from the folder it started in.
public enum SessionResume {
  /// The first of `candidates` that exists and holds the session's transcript; nil when none can resume it.
  public static func folder(session: String, candidates: [String], projects: String,
                            exists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> String? {
    guard WorkStore.isSessionID(session) else { return nil }
    return candidates.first { folder in
      exists(folder) && exists("\(projects)/\(ClaudeProjectFolder.name(for: folder))/\(session).jsonl")
    }
  }
}
