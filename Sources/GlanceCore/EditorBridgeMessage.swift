import Foundation

/// What the Glance extension, running in an editor tab's VS Code extension host, tells Glance Studio over the editor
/// bridge (a unix socket, one JSON object per line). Stage 2 adds the messages the app sends back.
public enum EditorBridgeMessage: Equatable, Sendable {
  /// The extension host of the editor tab for this workspace folder connected.
  case hello(folder: String)
  /// The user asked for a shell: open a Glance Studio tab in `cwd`.
  case openTerminal(cwd: String)
  /// ⌘W with no file open: close the editor tab.
  case closeTab
  /// Inline Ask, as in Razor Code (`EditorRequest`): start a box, a follow-up question, close or stop it.
  case askStart(InlineAsk.Request)
  case askFollowUp(id: String, question: String)
  case askStop(id: String)

  public static func decode(_ line: String) -> EditorBridgeMessage? {
    guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          let type = object["type"] as? String else { return nil }
    switch type {
    case "hello": return (object["folder"] as? String).map { .hello(folder: $0) }
    case "openTerminal": return (object["cwd"] as? String).map { .openTerminal(cwd: $0) }
    case "closeTab": return .closeTab
    case "askStart": return InlineAsk.Request(object: object).map { .askStart($0) }
    case "askFollowUp":
      guard let id = object["id"] as? String, let question = object["question"] as? String else { return nil }
      return .askFollowUp(id: id, question: question)
    case "askStop": return (object["id"] as? String).map { .askStop(id: $0) }
    default: return nil
    }
  }

  /// One line of JSON, without the newline.
  public var line: String {
    let object: [String: Any]
    switch self {
    case .hello(let folder): object = ["type": "hello", "folder": folder]
    case .openTerminal(let cwd): object = ["type": "openTerminal", "cwd": cwd]
    case .closeTab: object = ["type": "closeTab"]
    case .askStart(let r):
      object = ["type": "askStart", "id": r.id, "path": r.path, "start": r.start, "end": r.end, "text": r.text,
                "before": r.before, "after": r.after, "question": r.question]
    case .askFollowUp(let id, let question): object = ["type": "askFollowUp", "id": id, "question": question]
    case .askStop(let id): object = ["type": "askStop", "id": id]
    }
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    return String(decoding: data, as: UTF8.self)
  }
}

/// Splits bytes read from a socket into lines. A line longer than 1 MB is dropped, so a client that never sends a
/// newline can't grow the buffer forever.
public struct JSONLines {
  private var pending = Data()
  private var discarding = false
  private static let limit = 1 << 20

  public init() {}

  public mutating func append(_ data: Data) -> [String] {
    var lines: [String] = []
    for byte in data {
      if byte == UInt8(ascii: "\n") {
        if !discarding {
          let line = String(decoding: pending, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
          if !line.isEmpty { lines.append(line) }
        }
        pending.removeAll(keepingCapacity: true)
        discarding = false
      } else if !discarding {
        pending.append(byte)
        if pending.count > Self.limit {
          pending.removeAll()
          discarding = true
        }
      }
    }
    return lines
  }
}
