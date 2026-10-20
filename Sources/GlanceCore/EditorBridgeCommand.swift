import Foundation

/// What Glance Studio tells the Glance extension in an editor tab over the editor bridge (one JSON object per line).
/// The other direction is `EditorBridgeMessage`.
public enum EditorBridgeCommand: Equatable, Sendable {
  /// Show a file (absolute path), at a 1-based line and column when given.
  case open(path: String, line: Int?, column: Int?)
  /// Claude's latest changed lines, by path relative to the editor tab's root. It replaces what was shown before; an
  /// empty map clears it.
  case claudeChanges([String: [LineMark]])
  /// The files Claude edited in the latest session, relative to the root, for the Claude badges and view.
  case claudeFiles([String])
  /// What Claude is doing in an inline box the extension opened (`InlineAsk.eventObject`).
  case askEvent(InlineAsk.Event, request: InlineAsk.Request)

  public var line: String {
    var object: [String: Any]
    switch self {
    case .open(let path, let line, let column):
      object = ["type": "open", "path": path]
      if let line { object["line"] = line }
      if let column { object["column"] = column }
    case .claudeChanges(let files):
      object = ["type": "claudeChanges",
                "files": files.mapValues { $0.map { ["start": $0.start, "end": $0.end, "kind": $0.kind.rawValue] } }]
    case .claudeFiles(let paths):
      object = ["type": "claudeFiles", "paths": paths]
    case .askEvent(let event, let request):
      object = InlineAsk.eventObject(event, for: request)
      object["type"] = "askEvent"
    }
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    return String(decoding: data, as: UTF8.self)
  }
}
