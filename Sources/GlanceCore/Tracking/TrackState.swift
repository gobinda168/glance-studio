import Foundation

/// A repository's tracking state, rewritten by every hook under the repository's lock: the last fingerprint of each
/// worktree, the tool calls running now, who made each uncommitted file's current content, the sessions, and the
/// warnings each session was told.
public struct TrackState: Codable, Equatable, Sendable {
  public struct OpenCall: Codable, Equatable, Sendable {
    public var session: String
    public var worktree: String
    /// Path → content hash of the worktree's uncommitted files when the call started (hashes only, to keep the state
    /// file small); nil when it had too many files to fingerprint, and then the call records nothing.
    public var hashes: [String: String]?
    public var started: Date
    /// Other sessions whose calls in the same worktree overlapped this one.
    public var overlapped: [String]

    public init(session: String, worktree: String, hashes: [String: String]?, started: Date,
                overlapped: [String] = []) {
      self.session = session
      self.worktree = worktree
      self.hashes = hashes
      self.started = started
      self.overlapped = overlapped
    }
  }

  public struct Authorship: Codable, Equatable, Sendable {
    /// The content hash the author left; a file whose hash differs now was changed since, outside Claude.
    public var hash: String
    public var author: Author

    public init(hash: String, author: Author) {
      self.hash = hash
      self.author = author
    }
  }

  /// The repository's common git folder.
  public var repo: String
  public var fingerprints: [String: Fingerprint] = [:]
  /// Worktree → when the look that took its stored fingerprint began, in seconds since 1970. Hooks fingerprint before
  /// taking the lock, so an older look must not replace a newer one. Seconds, not a Date: the ledger saves dates as
  /// ISO 8601 without fractions, and parallel hooks' looks are often in the same second.
  public var looked: [String: Double] = [:]
  /// By tool_use_id.
  public var open: [String: OpenCall] = [:]
  /// Worktree → path → who made its current content.
  public var authors: [String: [String: Authorship]] = [:]
  public var sessions: [String: TrackedSession] = [:]
  /// Session → warning kind → the items it was already told about.
  public var told: [String: [String: [String]]] = [:]
  public var pruned: Date?

  public init(repo: String) {
    self.repo = repo
  }

  /// Every field but `repo` may be missing or in another shape (a state file from an older or newer Glance): that
  /// field starts empty rather than the whole state.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    repo = try container.decode(String.self, forKey: .repo)
    fingerprints = (try? container.decodeIfPresent([String: Fingerprint].self, forKey: .fingerprints)) ?? [:]
    looked = (try? container.decodeIfPresent([String: Double].self, forKey: .looked)) ?? [:]
    open = (try? container.decodeIfPresent([String: OpenCall].self, forKey: .open)) ?? [:]
    authors = (try? container.decodeIfPresent([String: [String: Authorship]].self, forKey: .authors)) ?? [:]
    sessions = (try? container.decodeIfPresent([String: TrackedSession].self, forKey: .sessions)) ?? [:]
    told = (try? container.decodeIfPresent([String: [String: [String]]].self, forKey: .told)) ?? [:]
    pruned = (try? container.decodeIfPresent(Date.self, forKey: .pruned)) ?? nil
  }

  /// Folds a ledger record into the state.
  public mutating func apply(_ record: LedgerRecord) {
    switch record.kind {
    case .sessionStart:
      guard let id = record.session else { return }
      let task = sessions[id]?.task
      sessions[id] = TrackedSession(id: id, worktree: record.worktree, branch: record.branch, pid: record.pid,
                                    terminal: record.terminal, task: task, started: record.t, ended: nil)
    case .sessionEnd:
      guard let id = record.session else { return }
      sessions[id]?.ended = record.t
    case .prompt:
      guard let id = record.session, sessions[id]?.task == nil else { return }
      sessions[id]?.task = record.text
    case .change, .outside, .ambiguous:
      let author: Author = switch record.kind {
      case .change: .session(record.session ?? "")
      case .ambiguous: .ambiguous(record.sessions ?? [])
      default: .outside
      }
      for file in record.files ?? [] {
        authors[record.worktree, default: [:]][file.path] = Authorship(hash: file.hash, author: author)
      }
      if let id = record.session { sessions[id]?.worktree = record.worktree }
    }
  }

  /// Forgets what is no longer needed: sessions that ended before `cutoff`, or aren't live and started before it;
  /// what the forgotten sessions were told; and the fingerprints and authors of worktrees `exists` says are gone.
  public mutating func prune(before cutoff: Date, alive: (Int32) -> Bool, exists: (String) -> Bool) {
    sessions = sessions.filter { _, session in
      if let ended = session.ended, ended < cutoff { return false }
      return session.isLive(alive) || session.started >= cutoff
    }
    told = told.filter { sessions[$0.key] != nil }
    fingerprints = fingerprints.filter { exists($0.key) }
    looked = looked.filter { exists($0.key) }
    authors = authors.filter { exists($0.key) }
  }

  /// The worktree's latest fingerprint, from a look that began at `time`; ignored when the stored one is from a look
  /// that began later. Authors of files no longer uncommitted are forgotten. A `tooMany` fingerprint only marks the
  /// stored one `tooMany`: its entries (the hash cache) and the authors stay as they were.
  public mutating func setFingerprint(_ print: Fingerprint, for worktree: String, at time: Date? = nil) {
    if let time {
      if let stored = looked[worktree], stored > time.timeIntervalSince1970 { return }
      looked[worktree] = time.timeIntervalSince1970
    }
    guard !print.tooMany else {
      fingerprints[worktree, default: print].tooMany = true
      return
    }
    fingerprints[worktree] = print
    guard var known = authors[worktree] else { return }
    known = known.filter { print.entries[$0.key] != nil }
    authors[worktree] = known.isEmpty ? nil : known
  }
}

extension TrackState {
  /// The id of the live session running under the `claude` process `claudePID`, nil when there is no such process
  /// or session. Several matches (a reused pid) resolve to the most recently started.
  public func liveSession(claudePID: Int32?, alive: (Int32) -> Bool = ProcessTree.isClaude) -> String? {
    guard let claudePID else { return nil }
    return sessions.values
      .filter { $0.pid == claudePID && $0.ended == nil && $0.isLive(alive) }
      .max { $0.started < $1.started }?.id
  }
}
