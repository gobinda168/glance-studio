import Foundation

/// Settings → Orb channel → "When Claude needs you".
public enum NeedsYouOpen: String, CaseIterable, Sendable {
  case glow, card, cardAndKeyboard

  public var title: String {
    switch self {
    case .glow: "Glow only (click the orb)"
    case .card: "Open the card"
    case .cardAndKeyboard: "Open the card and take the keyboard"
    }
  }
}

public enum NeedsYouRules {
  public enum Open: Equatable, Sendable { case none, card, cardAndKeyboard }

  /// A new prompt: whether its card opens by itself. Never for the split the user is looking at.
  public static func open(setting: NeedsYouOpen, splitFocused: Bool) -> Open {
    guard !splitFocused else { return .none }
    switch setting {
    case .glow: return .none
    case .card: return .card
    case .cardAndKeyboard: return .cardAndKeyboard
    }
  }

  /// The orb's tooltip: "my-app needs you: Bash command".
  public static func caption(_ prompt: PendingPrompt) -> String { "\(prompt.project) needs you: \(what(prompt))" }

  /// The card header's second half.
  public static func what(_ prompt: PendingPrompt) -> String {
    switch prompt.kind {
    case .question: "a question"
    case .plan: "plan approval"
    case .permission: prompt.call.name == "Bash" ? "Bash command" : prompt.call.name
    }
  }
}

/// What a prompt card shows above its answers.
public enum PromptDetails: Equatable, Sendable {
  case command(String)
  case edit(path: String, added: Int, removed: Int)
  case fields([String])
  case plan(String)
  /// The dialog's own lines (a subagent's tool, or a tool with nothing to show).
  case screen([String])
  case none

  private static let fieldKeys = ["file_path", "path", "url", "pattern", "query", "notebook_path"]

  public static func of(_ prompt: PendingPrompt) -> PromptDetails {
    let input: [String: JSONValue] = if case .object(let object) = prompt.call.input { object } else { [:] }
    func string(_ key: String) -> String? { if case .string(let value)? = input[key] { value } else { nil } }
    func lines(_ text: String?) -> Int { text.map { $0.isEmpty ? 0 : $0.components(separatedBy: "\n").count } ?? 0 }
    switch prompt.call.name {
    case "AskUserQuestion": return .none
    case "ExitPlanMode": return string("plan").map(PromptDetails.plan) ?? .screen(prompt.screen.detail)
    case "Bash": return string("command").map(PromptDetails.command) ?? .screen(prompt.screen.detail)
    case "Edit":
      guard let path = string("file_path") else { break }
      return .edit(path: path, added: lines(string("new_string")), removed: lines(string("old_string")))
    case "Write":
      guard let path = string("file_path") else { break }
      return .edit(path: path, added: lines(string("content")), removed: 0)
    case "MultiEdit":
      guard let path = string("file_path"), case .array(let edits)? = input["edits"] else { break }
      var added = 0, removed = 0
      for case .object(let edit) in edits {
        if case .string(let new)? = edit["new_string"] { added += lines(new) }
        if case .string(let old)? = edit["old_string"] { removed += lines(old) }
      }
      return .edit(path: path, added: added, removed: removed)
    case "Agent", "Task":
      return .screen(prompt.screen.detail)
    default:
      let fields = fieldKeys.compactMap { key in string(key).map { "\(key): \($0)" } }
      if !fields.isEmpty { return .fields(fields) }
    }
    return prompt.screen.detail.isEmpty ? .none : .screen(prompt.screen.detail)
  }
}

/// Which mode every orb shows: fn held first, then a Claude prompt, then a meeting / notification / Tickets card,
/// then the orb channel's status, then the panel's.
public enum OrbModes {
  public static func pick(panel: String, channel: String?, attention: Bool, prompt: Bool) -> String {
    if channel == "listening" { return "listening" }
    if prompt { return "waiting" }
    if attention { return "meeting" }
    return channel ?? panel
  }
}
