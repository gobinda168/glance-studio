import Foundation

/// One row of the editor chat, read from a Claude Code transcript.
public enum ChatItem: Equatable, Sendable {
  /// Something the user sent. `context` is the Razor Code context line (file, selection), shown as a chip.
  case user(text: String, context: String?)
  /// Claude's text, split into the pane's blocks.
  case assistant(blocks: [Block])
  /// A tool Claude used: "Edit" and "src/editor.js".
  case tool(name: String, detail: String)
  /// A tool call auto mode refused.
  case denied(name: String, detail: String)
}

/// The conversation the pane shows in chat mode.
public struct ChatThread: Equatable, Sendable {
  public var items: [ChatItem]
  /// The last prompt has no final answer yet.
  public var working: Bool
  /// Only the transcript's tail was read: earlier messages aren't in `items`.
  public var truncated: Bool

  public init(items: [ChatItem] = [], working: Bool = false, truncated: Bool = false) {
    self.items = items
    self.working = working
    self.truncated = truncated
  }

  /// For `glance.chatThread`: `{working, truncated, items: [{kind, …}]}`.
  public var payload: [String: Any] {
    ["working": working, "truncated": truncated, "items": items.map(\.payload)]
  }
}

extension ChatItem {
  var payload: [String: Any] {
    switch self {
    case .user(let text, let context):
      return ["kind": "user", "text": text, "context": context ?? NSNull()]
    case .assistant(let blocks):
      return ["kind": "assistant", "blocks": blocks.map {
        ["kind": $0.kind.rawValue, "markdown": $0.markdown, "lang": $0.lang ?? NSNull()] as [String: Any]
      }]
    case .tool(let name, let detail):
      return ["kind": "tool", "name": name, "detail": detail]
    case .denied(let name, let detail):
      return ["kind": "denied", "name": name, "detail": detail]
    }
  }
}

/// Turns a transcript into chat rows. Like `Transcript`, it skips thinking, meta and subagent (sidechain) entries;
/// unlike it, it keeps the whole conversation and a row per tool call.
public enum ChatTranscript {
  public static func thread(jsonl: String, root: String?, truncated: Bool = false) -> ChatThread {
    var items: [ChatItem] = []
    var toolRows: [String: Int] = [:] // tool_use id → its row
    var working = false
    for line in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
        let message = entry["message"] as? [String: Any],
        entry["isSidechain"] as? Bool != true, entry["isMeta"] as? Bool != true
      else { continue }
      switch entry["type"] as? String {
      case "user":
        let content = message["content"]
        if Transcript.isPrompt(content) {
          guard let text = promptText(content), !isCommandEcho(text) else { continue }
          let (body, context) = ChatMessage.split(text)
          items.append(.user(text: body, context: context))
          working = true
        } else {
          for block in content as? [[String: Any]] ?? [] where block["type"] as? String == "tool_result" {
            guard block["is_error"] as? Bool == true, let id = block["tool_use_id"] as? String,
              let row = toolRows[id], isDenial(resultText(block["content"])),
              case .tool(let name, let detail) = items[row]
            else { continue }
            items[row] = .denied(name: name, detail: detail)
          }
        }
      case "assistant":
        for block in message["content"] as? [[String: Any]] ?? [] {
          switch block["type"] as? String {
          case "text":
            let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { items.append(.assistant(blocks: Blocks.split(text))) }
          case "tool_use":
            let name = block["name"] as? String ?? "Tool"
            if let id = block["id"] as? String { toolRows[id] = items.count }
            items.append(.tool(name: name, detail: detail(tool: name, input: block["input"] as? [String: Any] ?? [:], root: root)))
          default:
            continue
          }
        }
        if let stop = message["stop_reason"] as? String, stop != "tool_use", stop != "pause_turn" { working = false }
      default:
        continue
      }
    }
    return ChatThread(items: items, working: working, truncated: truncated)
  }

  /// A session's name in the picker: its first prompt on one line (the editor context line left out), cut short.
  public static func title(jsonl: String, limit: Int = 80) -> String? {
    for line in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
        entry["type"] as? String == "user", entry["isSidechain"] as? Bool != true, entry["isMeta"] as? Bool != true,
        let message = entry["message"] as? [String: Any], Transcript.isPrompt(message["content"]),
        let text = promptText(message["content"]), !isCommandEcho(text)
      else { continue }
      let words = ChatMessage.split(text).text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
      if words.isEmpty { continue }
      return words.count > limit ? String(words.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…" : words
    }
    return nil
  }

  static func promptText(_ content: Any?) -> String? {
    if let text = content as? String { return text }
    let texts = (content as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
    return texts.isEmpty ? nil : texts.joined(separator: "\n")
  }

  /// Slash commands and their output are written as user entries (`<command-name>/clear</command-name>`).
  static func isCommandEcho(_ text: String) -> Bool {
    text.hasPrefix("<command-") || text.hasPrefix("<local-command-")
  }

  static func resultText(_ content: Any?) -> String {
    if let text = content as? String { return text }
    return (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
  }

  /// Auto mode's refusal: "Permission for this action was denied by the Claude Code auto mode classifier…".
  static func isDenial(_ text: String) -> Bool {
    let lower = text.lowercased()
    return lower.contains("auto mode classifier") || (lower.contains("permission") && lower.contains("denied"))
  }

  /// What a tool row says after the tool's name: a path (relative to the project when inside it), a command's first
  /// line, a pattern. At most 80 characters.
  static func detail(tool: String, input: [String: Any], root: String?) -> String {
    func path(_ key: String) -> String? {
      guard let path = input[key] as? String else { return nil }
      if let root, let relative = PathLinks.relative(SessionMatch.normalize(path, home: NSHomeDirectory()),
                                                     inRoot: SessionMatch.normalize(root, home: NSHomeDirectory())) {
        return relative
      }
      return (path as NSString).lastPathComponent
    }
    let text: String? = switch tool {
    case "Read", "Edit", "MultiEdit", "Write": path("file_path")
    case "NotebookEdit": path("notebook_path")
    case "Bash": (input["command"] as? String)?.components(separatedBy: "\n").first
    case "Grep", "Glob": input["pattern"] as? String
    case "WebFetch": input["url"] as? String
    case "WebSearch": input["query"] as? String
    case "Task", "Agent": input["description"] as? String
    default: nil
    }
    let line = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return line.count > 80 ? String(line.prefix(79)) + "…" : line
  }
}

/// The context line Razor Code puts in front of a chat message, and reading it back for the chip.
public enum ChatMessage {
  static let prefix = "[Razor Code: "

  /// "src/x.ts, lines 40–52 selected", "src/x.ts, line 40 selected", "src/x.ts", or nil without a file.
  public static func context(file: String?, lines: ClosedRange<Int>?) -> String? {
    guard let file else { return nil }
    guard let lines else { return file }
    return lines.lowerBound == lines.upperBound
      ? "\(file), line \(lines.lowerBound) selected"
      : "\(file), lines \(lines.lowerBound)–\(lines.upperBound) selected"
  }

  public static func compose(_ text: String, context: String?) -> String {
    guard let context else { return text }
    return prefix + context + "] " + text
  }

  public static func split(_ message: String) -> (text: String, context: String?) {
    guard message.hasPrefix(prefix), let close = message.range(of: "] ") else { return (message, nil) }
    let context = String(message[message.index(message.startIndex, offsetBy: prefix.count)..<close.lowerBound])
    return (String(message[close.upperBound...]), context)
  }
}
