import Foundation

/// What a relaunch types into a terminal that was running Claude Code when the app quit: `claude --resume <id>`, the
/// same conversation again. Any other command is never run again.
public enum ClaudeResume {
  /// The resume command for a shell whose running command was `running` and whose Claude session was `sessionID`; nil
  /// when the shell wasn't running Claude (an `ls`, a build, a prompt) or the session is unknown.
  public static func command(running: String?, sessionID: String?) -> String? {
    guard let running, let sessionID, isSessionID(sessionID), runsClaude(running) else { return nil }
    return "claude --resume \(sessionID)"
  }

  /// `claude`, `claude -c`, `FOO=1 claude --model opus`, `~/.local/bin/claude`: the command's program is Claude Code.
  /// A pipeline or a list of commands isn't one session to bring back.
  static func runsClaude(_ command: String) -> Bool {
    guard !command.contains(where: { "|;&<>`$(){}\n".contains($0) }) else { return false }
    let words = command.split(whereSeparator: \.isWhitespace)
    guard let program = words.first(where: { !$0.contains("=") || $0.hasPrefix("/") || $0.hasPrefix("~") }) else {
      return false
    }
    return program.split(separator: "/").last == "claude"
  }

  /// Session IDs are UUIDs; anything else is never typed into a shell.
  static func isSessionID(_ id: String) -> Bool {
    UUID(uuidString: id) != nil
  }
}
