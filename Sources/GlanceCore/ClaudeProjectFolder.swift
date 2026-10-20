import Foundation

/// Where Claude Code keeps a folder's transcripts: `~/.claude/projects/<name>/<session>.jsonl`, where the name is the
/// folder's path with everything but letters and digits turned into "-" ("/Users/me/Code/glance" → "-Users-me-Code-glance").
public enum ClaudeProjectFolder {
  public static func name(for path: String) -> String {
    String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
  }

  /// "now", "5m", "3h", "2d": how long ago, in the sidebar's words.
  public static func ago(_ date: Date, now: Date = Date()) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    if seconds < 45 { return "now" }
    if seconds < 3600 { return "\(Int((seconds / 60).rounded()))m" }
    if seconds < 86400 { return "\(Int((seconds / 3600).rounded()))h" }
    return "\(Int((seconds / 86400).rounded()))d"
  }
}
