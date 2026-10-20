import Foundation

/// One change Claude made to a file, as its tool call described it.
public struct FileEdit: Equatable, Sendable {
  public enum Change: Equatable, Sendable {
    case replace(old: String, new: String, replaceAll: Bool)
    case write(content: String)
  }

  /// Absolute, as in the tool call.
  public var path: String
  public var change: Change

  public init(path: String, change: Change) {
    self.path = path
    self.change = change
  }
}

/// Finds what Claude changed in its latest edit turn. Like `Transcript`, this knows an internal, undocumented format.
public enum ClaudeEdits {
  private struct Pending {
    let toolUseID: String?
    let edit: FileEdit
  }

  /// The successful `Edit`, `MultiEdit` and `Write` calls of the most recent turn that made any, oldest first. A turn
  /// starts at a real user prompt; subagent (sidechain) prompts don't start one, but subagent edits count.
  public static func latestEdits(jsonl: String) -> [FileEdit] {
    var turns: [[Pending]] = []
    var current: [Pending] = []
    var failed = Set<String>()

    for line in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            let message = entry["message"] as? [String: Any],
            entry["isMeta"] as? Bool != true else { continue }
      switch entry["type"] as? String {
      case "user":
        for block in message["content"] as? [[String: Any]] ?? []
        where block["type"] as? String == "tool_result" && block["is_error"] as? Bool == true {
          if let id = block["tool_use_id"] as? String { failed.insert(id) }
        }
        if entry["isSidechain"] as? Bool != true, Transcript.isPrompt(message["content"]) {
          if !current.isEmpty { turns.append(current) }
          current = []
        }
      case "assistant":
        for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_use" {
          current += edits(in: block)
        }
      default:
        continue
      }
    }
    if !current.isEmpty { turns.append(current) }

    for turn in turns.reversed() {
      let kept = turn.filter { !failed.contains($0.toolUseID ?? "") }.map(\.edit)
      if !kept.isEmpty { return kept }
    }
    return []
  }

  /// Every file a successful `Edit`, `MultiEdit` or `Write` touched in this transcript (one Claude session, all its
  /// turns, subagents included), sorted and without repeats.
  public static func editedPaths(jsonl: String) -> [String] {
    var touched: [Pending] = []
    var failed = Set<String>()
    for line in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            let message = entry["message"] as? [String: Any],
            entry["isMeta"] as? Bool != true else { continue }
      for block in message["content"] as? [[String: Any]] ?? [] {
        switch (entry["type"] as? String, block["type"] as? String) {
        case ("user", "tool_result") where block["is_error"] as? Bool == true:
          if let id = block["tool_use_id"] as? String { failed.insert(id) }
        case ("assistant", "tool_use"):
          touched += edits(in: block)
        default:
          continue
        }
      }
    }
    return Set(touched.filter { !failed.contains($0.toolUseID ?? "") }.map(\.edit.path)).sorted()
  }

  private static func edits(in block: [String: Any]) -> [Pending] {
    guard let name = block["name"] as? String, let input = block["input"] as? [String: Any],
          let path = input["file_path"] as? String else { return [] }
    let id = block["id"] as? String
    func replace(_ item: [String: Any]) -> Pending? {
      guard let old = item["old_string"] as? String, let new = item["new_string"] as? String else { return nil }
      return Pending(toolUseID: id, edit: FileEdit(path: path, change: .replace(old: old, new: new, replaceAll: item["replace_all"] as? Bool ?? false)))
    }
    switch name {
    case "Edit":
      return replace(input).map { [$0] } ?? []
    case "MultiEdit":
      return (input["edits"] as? [[String: Any]] ?? []).compactMap(replace)
    case "Write":
      guard let content = input["content"] as? String else { return [] }
      return [Pending(toolUseID: id, edit: FileEdit(path: path, change: .write(content: content)))]
    default:
      return []
    }
  }
}
