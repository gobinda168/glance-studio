import Foundation

/// Whether Claude starts on a pull request by itself (spec 2026-10-08-pr-ask-lists-design.md, "Stage 1"): the
/// "Claude reads pull requests on its own" setting, off by default.
public enum AutoClaude {
  /// What a PR page does with Claude's read when it loads.
  public enum Read: Equatable, Sendable {
    /// The read of this head commit is in the cache.
    case showCached
    /// Run one now.
    case start
    /// One is running, failed (Retry), or Claude Code is missing: leave it.
    case wait
    /// The setting is off: show "Ask Claude to read this PR".
    case offer
  }

  /// `cached`: the cache has this head's read. `busy`: a read is under way, failed, or Claude Code is missing.
  public static func read(auto: Bool, cached: Bool, busy: Bool) -> Read {
    if cached { return .showCached }
    if busy { return .wait }
    return auto ? .start : .offer
  }
}
