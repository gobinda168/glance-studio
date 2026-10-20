import Foundation

/// Where an editor chat message goes: into a terminal split running Claude Code in the project, or to Glance's own
/// headless session.
public enum ChatRoute: Equatable, Sendable {
  /// An index into the surfaces given to `decide`.
  case terminal(index: Int)
  case headless

  /// A terminal split and its foreground process.
  public struct Surface: Equatable, Sendable {
    public let pwd: String?
    public let executable: String?
    public let arguments: [String]

    public init(pwd: String?, executable: String?, arguments: [String]) {
      self.pwd = pwd
      self.executable = executable
      self.arguments = arguments
    }
  }

  /// `surfaces` in the order the user last used them (front window first, its focused split first): the first one in
  /// exactly the project's folder whose foreground process is Claude Code.
  public static func decide(root: String, surfaces: [Surface], home: String = NSHomeDirectory()) -> ChatRoute {
    for (index, surface) in surfaces.enumerated()
    where SessionMatch.matches(sessionCwd: surface.pwd, surfacePwd: root, home: home)
      && isClaude(executable: surface.executable, arguments: surface.arguments) {
      return .terminal(index: index)
    }
    return .headless
  }

  /// The native installer's binary is named after its version (`versions/2.1.285`) but runs as `claude`; the npm one is
  /// `claude.exe` or a node script inside `@anthropic-ai/claude-code`.
  public static func isClaude(executable: String?, arguments: [String]) -> Bool {
    let names = [arguments.first, executable].compactMap { $0 }.map { ($0 as NSString).lastPathComponent }
    if names.contains(where: { $0 == "claude" || $0 == "claude.exe" }) { return true }
    return arguments.contains { $0.contains("/@anthropic-ai/claude-code/") }
  }
}

/// What the composer shows: the context chip, the route chip, send or stop, and a notice (an error, a fallback).
public struct ChatComposer: Equatable, Sendable {
  public var context: String?
  public var route: ChatRoute
  public var working: Bool
  public var notice: String?
  /// This project's headless chat sessions for the picker, and the one the chat is on (nil: a blank chat).
  public var sessions: [ChatSessionEntry]
  public var activeSession: String?

  public init(context: String?, route: ChatRoute, working: Bool, notice: String?,
              sessions: [ChatSessionEntry] = [], activeSession: String? = nil) {
    self.context = context
    self.route = route
    self.working = working
    self.notice = notice
    self.sessions = sessions
    self.activeSession = activeSession
  }

  /// For `glance.chatComposer`.
  public var payload: [String: Any] {
    let headless = route == .headless
    return ["context": context ?? NSNull(), "route": headless ? "headless" : "terminal",
            "routeLabel": headless ? "Headless · Auto" : "Terminal", "working": working, "notice": notice ?? NSNull(),
            "sessions": sessions.map { ["id": $0.id, "title": $0.title ?? NSNull(), "updated": $0.updated.timeIntervalSince1970] as [String: Any] },
            "active": activeSession ?? NSNull()]
  }
}

/// Glance's headless Claude Code session for the editor chat: how it's started and how its stdout ends a turn.
public enum ChatSession {
  /// A real session (transcript, hooks) in auto mode; messages arrive as stream-json lines on stdin.
  public static func arguments(sessionID: String, resume: Bool) -> [String] {
    ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
     "--permission-mode", "auto", resume ? "--resume" : "--session-id", sessionID]
  }

  public enum Outcome: Equatable, Sendable {
    case done
    case failed(String)
  }

  /// The `result` line that ends every turn; nil for any other line.
  public static func outcome(line: String) -> Outcome? {
    guard line.contains("\"result\""),
      let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
      object["type"] as? String == "result"
    else { return nil }
    guard object["is_error"] as? Bool == true else { return .done }
    return .failed((object["result"] as? String) ?? (object["subtype"] as? String) ?? "Claude Code failed")
  }

  /// Resume the saved session while its transcript is there; otherwise (none saved, or it was deleted) a new one.
  public static func launchPlan(saved: String?, transcriptExists: Bool, newID: () -> String) -> (id: String, resume: Bool) {
    if let saved, transcriptExists { return (saved, true) }
    return (newID(), false)
  }

  /// Claude Code's folder for a project's transcripts: every character but ASCII letters and digits becomes "-".
  public static func projectFolder(cwd: String) -> String {
    String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
  }
}
