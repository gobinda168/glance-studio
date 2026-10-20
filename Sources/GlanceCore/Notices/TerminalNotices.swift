import Foundation

/// Terminal desktop notifications (Claude Code's "needs your permission" / "waiting for your input" come this way
/// in Glance Studio, whose TERM_PROGRAM is ghostty) and finished Claude turns, as notices.
public enum TerminalNotices {
  public static func notice(surface: String, cwd: String?, title: String, body: String, at date: Date) -> Notice {
    let isClaude = (title + " " + body).range(of: "claude", options: .caseInsensitive) != nil
    let folder = cwd.map { ($0 as NSString).lastPathComponent }
    return Notice(id: "claude:\(surface):\(date.timeIntervalSince1970)", source: .claude,
                  kind: isClaude ? .claudeNeedsInput : .terminalAlert,
                  title: isClaude ? (folder ?? title) : title,
                  place: isClaude ? "Claude Code" : "Terminal",
                  preview: body.isEmpty ? title : body, date: date, threadKey: "claude:\(surface)",
                  target: .terminal(surface: surface, cwd: cwd))
  }

  public static func finished(cwd: String, at date: Date) -> Notice {
    Notice(id: "claude-done:\(cwd):\(date.timeIntervalSince1970)", source: .claude, kind: .claudeFinished,
           title: (cwd as NSString).lastPathComponent, place: "Claude Code", preview: "Claude finished its turn.",
           date: date, threadKey: "claude:\(cwd)", target: .terminal(surface: nil, cwd: cwd))
  }
}
