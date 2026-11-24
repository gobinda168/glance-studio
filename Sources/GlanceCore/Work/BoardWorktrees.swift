import Foundation

/// A worktree row in Command's side bar (spec §5 "Where").
public struct BoardWorktree: Equatable, Identifiable, Sendable {
  public var path: String
  public var branch: String?
  public var project: String
  public var repo: String
  public var main: String
  public var live: Bool
  /// False once it was removed: its recap comes from the records.
  public var exists: Bool
  public var lastActive: Date?
  /// Its sessions' ids, newest first.
  public var sessions: [String]
  public var id: String { path }

  /// Public because the app builds one for a main checkout it opens a recap for.
  public init(path: String, branch: String?, project: String, repo: String, main: String, live: Bool, exists: Bool,
              lastActive: Date?, sessions: [String]) {
    self.path = path; self.branch = branch; self.project = project; self.repo = repo; self.main = main; self.live = live
    self.exists = exists; self.lastActive = lastActive; self.sessions = sessions
  }
}

public enum BoardWorktrees {
  /// Live ones first, then Closed, the most recently active first; every worktree git lists plus those only the ledger
  /// remembers. The main checkout only while a session is live in it.
  public static func rows(trees: [RepoTree]) -> [BoardWorktree] {
    var rows: [BoardWorktree] = []
    for tree in trees {
      for worktree in tree.worktrees where !worktree.isMain || !worktree.live.isEmpty {
        rows.append(BoardWorktree(path: worktree.path, branch: worktree.branch, project: tree.name, repo: tree.repo, main: tree.main,
                                  live: !worktree.live.isEmpty, exists: true, lastActive: lastActive(worktree.sessions),
                                  sessions: newestFirst(worktree.sessions).map(\.id)))
      }
      for (path, sessions) in Dictionary(grouping: tree.orphans, by: \.worktree) {
        let ordered = newestFirst(sessions)
        rows.append(BoardWorktree(path: path, branch: ordered.first?.branch, project: tree.name, repo: tree.repo, main: tree.main,
                                  live: false, exists: false, lastActive: lastActive(sessions), sessions: ordered.map(\.id)))
      }
    }
    return rows.sorted {
      if $0.live != $1.live { return $0.live }
      return ($0.lastActive ?? .distantPast, $1.path) > ($1.lastActive ?? .distantPast, $0.path)
    }
  }

  /// What a closed worktree's last session proved, for its badge.
  public enum Outcome: Equatable, Sendable { case passed, failed, none }

  /// Failed when any check's latest run failed; passed only when every check ran and passed; otherwise none: no proof
  /// or part of it says nothing, so the badge isn't drawn.
  public static func outcome(of card: BoardCard?) -> Outcome {
    guard let card else { return .none }
    let results = card.dots.flatMap(\.checks).map(\.result)
    if card.failing || results.contains(.failed) { return .failed }
    if !results.isEmpty, results.allSatisfy({ $0 == .passed }) { return .passed }
    return .none
  }

  /// A path to compare worktrees by, without touching the disk: no trailing or doubled slash, no `.` or `..`, and the
  /// `/private` of `/private/tmp`, `/private/var` and `/private/etc` dropped, as macOS links them to `/tmp`, `/var`, `/etc`.
  public static func key(_ path: String) -> String {
    var parts: [Substring] = []
    for part in path.split(separator: "/") {
      if part == "." { continue }
      if part == ".." { _ = parts.popLast(); continue }
      parts.append(part)
    }
    if parts.count > 1, parts[0] == "private", ["tmp", "var", "etc"].contains(parts[1]) { parts.removeFirst() }
    return "/" + parts.joined(separator: "/")
  }

  private static func moment(_ session: TrackedSession) -> Date { session.ended ?? session.started }
  private static func lastActive(_ sessions: [TrackedSession]) -> Date? { sessions.map(moment).max() }
  private static func newestFirst(_ sessions: [TrackedSession]) -> [TrackedSession] {
    sessions.sorted { (moment($0), $1.id) > (moment($1), $0.id) }
  }
}
