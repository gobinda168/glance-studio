import Foundation

/// Reads Claude Code's session transcript (JSONL). The format is internal to Claude Code and undocumented,
/// so this is the only place that knows its shape.
public enum Transcript {
  /// The text Claude wrote since the user's last real prompt, text blocks joined by blank lines.
  /// Thinking, tool calls, tool results, meta entries and subagent (sidechain) entries are skipped.
  public static func lastReply(jsonl: String) -> String? {
    var texts: [String] = []
    for line in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
        let message = entry["message"] as? [String: Any]
      else { continue }
      if entry["isSidechain"] as? Bool == true || entry["isMeta"] as? Bool == true { continue }
      switch entry["type"] as? String {
      case "user" where isPrompt(message["content"]):
        texts.removeAll()
      case "assistant":
        for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "text" {
          if let text = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            texts.append(text)
          }
        }
      default:
        continue
      }
    }
    return texts.isEmpty ? nil : texts.joined(separator: "\n\n")
  }

  /// A user entry is a prompt when it carries text; tool results also arrive as user entries.
  static func isPrompt(_ content: Any?) -> Bool {
    if content is String { return true }
    guard let blocks = content as? [[String: Any]] else { return false }
    return blocks.contains { $0["type"] as? String == "text" }
      && !blocks.contains { $0["type"] as? String == "tool_result" }
  }
}

/// What one transcript line means for the panel: the user asked something, or Claude finished its turn.
public struct TurnEvent: Equatable, Sendable {
  public enum Kind: Equatable, Sendable { case prompt, done }
  public let kind: Kind
  /// The session's working directory, when the line carries one.
  public let cwd: String?

  public init(kind: Kind, cwd: String?) {
    self.kind = kind
    self.cwd = cwd
  }
}

/// A tool call Claude made (a `tool_use` block): which tool, with what input.
public struct ToolCall: Equatable, Sendable {
  public let id: String
  public let name: String
  public let input: JSONValue

  public init(id: String, name: String, input: JSONValue) {
    self.id = id
    self.name = name
    self.input = input
  }
}

/// A tool call started (it may now wait on a permission prompt) or got its result.
public struct ToolEvent: Equatable, Sendable {
  public enum Kind: Equatable, Sendable { case pending(ToolCall), settled(id: String) }
  public let kind: Kind
  public let cwd: String?

  public init(kind: Kind, cwd: String?) {
    self.kind = kind
    self.cwd = cwd
  }
}

extension Transcript {
  /// A prompt (Claude starts thinking) or a finished turn (the reply is ready). Tool use, tool results, meta and
  /// subagent (sidechain) entries mean nothing here.
  public static func turnEvent(line: String) -> TurnEvent? {
    guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
      let message = entry["message"] as? [String: Any],
      entry["isSidechain"] as? Bool != true, entry["isMeta"] as? Bool != true
    else { return nil }
    let cwd = entry["cwd"] as? String
    switch entry["type"] as? String {
    case "user" where isPrompt(message["content"]):
      return TurnEvent(kind: .prompt, cwd: cwd)
    case "assistant":
      guard let stop = message["stop_reason"] as? String, stop != "tool_use", stop != "pause_turn" else { return nil }
      return TurnEvent(kind: .done, cwd: cwd)
    default:
      return nil
    }
  }

  /// The tool calls a line starts (assistant `tool_use` blocks) or settles (user `tool_result` blocks). Subagent
  /// (sidechain) lines are skipped: their prompts show in the main session's dialog anyway.
  public static func toolEvents(line: String) -> [ToolEvent] {
    guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
      let message = entry["message"] as? [String: Any], entry["isSidechain"] as? Bool != true,
      let blocks = message["content"] as? [[String: Any]]
    else { return [] }
    let cwd = entry["cwd"] as? String
    switch entry["type"] as? String {
    case "assistant":
      return blocks.compactMap { block in
        guard block["type"] as? String == "tool_use", let id = block["id"] as? String,
          let name = block["name"] as? String else { return nil }
        return ToolEvent(kind: .pending(ToolCall(id: id, name: name, input: JSONValue(any: block["input"]))), cwd: cwd)
      }
    case "user":
      return blocks.compactMap { block in
        guard block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String else { return nil }
        return ToolEvent(kind: .settled(id: id), cwd: cwd)
      }
    default:
      return []
    }
  }
}
