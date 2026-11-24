import Foundation

/// What a terminal's foreground program is, for deciding whether text can be typed into it: a line typed into a running
/// Claude (or an editor) is a message to it, not a command.
public enum TerminalProgram {
  public enum State: Equatable, Sendable {
    /// A shell at its prompt: a command typed now runs.
    case shell
    /// Something else is in front, named by its command.
    case running(String)
    /// Couldn't be read.
    case unknown
  }

  /// `executable` and `arguments` are the foreground process's (`ProcessArguments`); nil when it couldn't be read.
  public static func state(executable: String?, arguments: [String], loginShell: String? = ProcessInfo.processInfo.environment["SHELL"]) -> State {
    guard let executable else { return .unknown }
    if CommandName.isShell(executable: executable, arguments: arguments, loginShell: loginShell) { return .shell }
    if ChatRoute.isClaude(executable: executable, arguments: arguments) { return .running("claude") }
    return .running(CommandName.name(of: arguments.first ?? executable))
  }

  /// Why `action` (a gerund: "resuming", "starting a session") mustn't be typed now; nil when the terminal is at a shell.
  public static func refusal(_ state: State, action: String) -> String? {
    switch state {
    case .shell: nil
    case .running("claude"): "Claude is running in this terminal, so \(action) here would go to it as a message. Use a new tab."
    case .running(let program): "\(program) is running in this terminal, so \(action) here would go to it. Quit it first, or use a new tab."
    case .unknown: "Couldn't tell what is running in this terminal, so \(action) isn't safe. Try again in a moment, or use a new tab."
    }
  }
}
