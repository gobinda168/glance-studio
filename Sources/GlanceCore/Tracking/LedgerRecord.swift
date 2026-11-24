import Foundation

/// One line of a repository's history ledger (spec §1, "The ledger"). Paths, statuses and hashes only; never file
/// contents.
public struct LedgerRecord: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case sessionStart = "session-start", sessionEnd = "session-end", prompt, change, outside, ambiguous
  }

  public struct File: Codable, Equatable, Sendable {
    public var path: String
    public var status: String
    public var hash: String

    public init(path: String, status: String, hash: String) {
      self.path = path
      self.status = status
      self.hash = hash
    }
  }

  public var t: Date
  public var kind: Kind
  public var worktree: String
  public var session: String?
  /// An ambiguous change's sessions.
  public var sessions: [String]?
  public var branch: String?
  public var tool: String?
  public var files: [File]?
  /// A session's `claude` process.
  public var pid: Int32?
  /// Where a session runs: "studio:<surface id>" or the terminal app (`TERM_PROGRAM`).
  public var terminal: String?
  /// A session's first prompt, trimmed.
  public var text: String?

  public init(t: Date, kind: Kind, worktree: String, session: String? = nil, sessions: [String]? = nil,
              branch: String? = nil, tool: String? = nil, files: [File]? = nil, pid: Int32? = nil,
              terminal: String? = nil, text: String? = nil) {
    self.t = t
    self.kind = kind
    self.worktree = worktree
    self.session = session
    self.sessions = sessions
    self.branch = branch
    self.tool = tool
    self.files = files
    self.pid = pid
    self.terminal = terminal
    self.text = text
  }
}

/// Who made an uncommitted file's current content.
public enum Author: Codable, Hashable, Sendable {
  case session(String)
  /// Changed while no Claude tool call ran in the worktree: by hand, a formatter, a build.
  case outside
  /// Changed while tool calls of these sessions overlapped in the worktree.
  case ambiguous([String])
}

/// A Claude session as the hooks saw it.
public struct TrackedSession: Codable, Equatable, Sendable {
  public var id: String
  public var worktree: String
  public var branch: String?
  public var pid: Int32?
  public var terminal: String?
  public var task: String?
  public var started: Date
  public var ended: Date?

  public init(id: String, worktree: String, branch: String?, pid: Int32?, terminal: String?, task: String?,
              started: Date, ended: Date?) {
    self.id = id
    self.worktree = worktree
    self.branch = branch
    self.pid = pid
    self.terminal = terminal
    self.task = task
    self.started = started
    self.ended = ended
  }

  /// Live while it hasn't ended and its `claude` process exists (a crash leaves no ghost).
  public func isLive(_ alive: (Int32) -> Bool) -> Bool {
    ended == nil && (pid.map(alive) ?? false)
  }
}
