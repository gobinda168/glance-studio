import Foundation

/// The part of a Claude Code hook's stdin JSON that change tracking reads (spec
/// 2026-10-22-multi-session-worktrees-design.md §1). A subagent's tool calls carry their parent's session id.
public struct HookInput: Equatable, Sendable {
  public var sessionID: String
  public var cwd: String
  public var event: String
  public var toolName: String?
  public var toolUseID: String?
  /// A Bash call's command line.
  public var command: String?
  public var prompt: String?

  public init(sessionID: String, cwd: String, event: String, toolName: String? = nil, toolUseID: String? = nil,
              command: String? = nil, prompt: String? = nil) {
    self.sessionID = sessionID
    self.cwd = cwd
    self.event = event
    self.toolName = toolName
    self.toolUseID = toolUseID
    self.command = command
    self.prompt = prompt
  }

  /// Nil when the data isn't a hook's input (no session_id, cwd or hook_event_name).
  public static func parse(_ data: Data) -> HookInput? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let session = object["session_id"] as? String, let cwd = object["cwd"] as? String,
          let event = object["hook_event_name"] as? String else { return nil }
    let tool = object["tool_input"] as? [String: Any]
    return HookInput(sessionID: session, cwd: cwd, event: event, toolName: object["tool_name"] as? String,
                     toolUseID: object["tool_use_id"] as? String, command: tool?["command"] as? String,
                     prompt: object["prompt"] as? String)
  }
}
