import Foundation

/// Inline Ask: a question about the lines selected in an editor tab, answered by Claude Code running headless
/// (`claude -p`, stream-json both ways) in the project folder. Claude may read the project but not change it; a change
/// the user asks for comes back as a `<replacement>` block for the selected lines, which the editor shows as a diff.
public enum InlineAsk {
  /// What the editor sends when the user asks. Lines are 1-based and inclusive; `text` is the selected lines' text and
  /// `before`/`after` the lines around them (the editor sends up to 40 each side), all joined with "\n".
  public struct Request: Equatable, Sendable {
    public let id: String
    public let path: String
    public let start: Int
    public let end: Int
    public let text: String
    public let before: String
    public let after: String
    public let question: String

    public init(id: String, path: String, start: Int, end: Int, text: String, before: String, after: String,
                question: String) {
      self.id = id
      self.path = path
      self.start = start
      self.end = end
      self.text = text
      self.before = before
      self.after = after
      self.question = question
    }

    /// From an editor's `askStart` message (a WKScriptMessage body or a decoded JSON line). Nil when anything is
    /// missing or of the wrong type.
    public init?(object: [String: Any]) {
      guard let id = object["id"] as? String, let path = object["path"] as? String,
            let start = object["start"] as? NSNumber, let end = object["end"] as? NSNumber,
            CFGetTypeID(start) != CFBooleanGetTypeID(), CFGetTypeID(end) != CFBooleanGetTypeID(),
            let text = object["text"] as? String, let question = object["question"] as? String else { return nil }
      self.init(id: id, path: path, start: start.intValue, end: end.intValue, text: text,
                before: object["before"] as? String ?? "", after: object["after"] as? String ?? "", question: question)
    }
  }

  public enum Event: Equatable, Sendable {
    /// More of the answer (Markdown), without any replacement block.
    case text(String)
    /// What Claude is doing now, e.g. "Reading Sources/App.swift…".
    case tool(String)
    /// The turn is over; the new text of the selected lines when the user asked for a change.
    case done(replacement: String?)
    case failed(String)
  }

  public static let rules = """
    You are answering inline in a code editor, about the lines the user selected. Answer briefly in Markdown.
    When the user asks for a change, end your answer with exactly one replacement block: the complete new text of the \
    selected lines only, keeping their indentation, with no code fence, like this:
    <replacement>
    the new lines
    </replacement>
    The block replaces only the selected lines: if other places need changing too, say so in words. When no change \
    was asked for, write no block. You can read files but never edit or write them.
    """

  public static func arguments(rules: String = rules) -> [String] {
    ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
     "--include-partial-messages", "--no-session-persistence",
     "--tools", "Read", "Grep", "Glob",
     "--settings", #"{"disableAllHooks":true}"#, "--strict-mcp-config",
     "--append-system-prompt", rules]
  }

  /// The first message of a box: the file, the numbered selection (marked `>`) with its context, and the question.
  public static func firstMessage(_ request: Request) -> String {
    func lines(_ text: String) -> [String] { text.isEmpty ? [] : text.components(separatedBy: "\n") }
    let before = lines(request.before)
    let selected = lines(request.text)
    var numbered: [String] = []
    for (i, line) in before.enumerated() { numbered.append("\(request.start - before.count + i)| \(line)") }
    for (i, line) in selected.enumerated() { numbered.append("\(request.start + i)> \(line)") }
    for (i, line) in lines(request.after).enumerated() { numbered.append("\(request.end + 1 + i)| \(line)") }
    let which = request.start == request.end ? "line \(request.start). Around it:"
      : "lines \(request.start)-\(request.end). Around them:"
    return "File: \(request.path)\nThe user selected \(which)\n" + numbered.joined(separator: "\n")
      + "\n\nQuestion: \(request.question)"
  }

  /// One stream-json user message, as a single line for Claude's stdin (without the newline).
  public static func userLine(_ text: String) -> String {
    let object: [String: Any] = ["type": "user", "message": ["role": "user", "content": text]]
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    return String(decoding: data, as: UTF8.self)
  }

  /// The `claude` executable: the first on `path` (the login shell's PATH), else one of its usual install places.
  public static func findClaude(path: String?, home: String, exists: (String) -> Bool) -> String? {
    let onPath = (path ?? "").split(separator: ":").map { "\($0)/claude" }
    let usual = ["\(home)/.claude/local/claude", "\(home)/.local/bin/claude", "/opt/homebrew/bin/claude",
                 "/usr/local/bin/claude"]
    return (onPath + usual).first(where: exists)
  }

  /// The first replacement block's text, without the one newline after its opening tag and before its closing one.
  public static func replacement(in text: String) -> String? {
    guard let open = text.range(of: openTag) else { return nil }
    let rest = text[open.upperBound...]
    let body = rest.range(of: closeTag).map { rest[..<$0.lowerBound] } ?? rest
    return trimmedBlock(String(body))
  }

  /// An event as JSON for the editor (both bridges): `{id, kind, …}`. `done` also carries the selection the request
  /// was made for, so the editor can tell whether the code changed meanwhile.
  public static func eventObject(_ event: Event, for request: Request) -> [String: Any] {
    var object: [String: Any] = ["id": request.id]
    switch event {
    case .text(let text):
      object["kind"] = "text"
      object["text"] = text
    case .tool(let label):
      object["kind"] = "tool"
      object["label"] = label
    case .done(let replacement):
      object["kind"] = "done"
      if let replacement { object["replacement"] = replacement }
      object["start"] = request.start
      object["end"] = request.end
      object["originalText"] = request.text
    case .failed(let message):
      object["kind"] = "failed"
      object["message"] = message
    }
    return object
  }

  static let openTag = "<replacement>"
  static let closeTag = "</replacement>"

  static func trimmedBlock(_ body: String) -> String {
    var text = Substring(body)
    if text.hasPrefix("\n") { text = text.dropFirst() }
    if text.hasSuffix("\n") { text = text.dropLast() }
    return String(text)
  }

  /// Turns Claude's stream-json output, line by line, into events. Text is passed on as it streams, except replacement
  /// blocks: those are held back (also when a tag arrives split over two pieces) and handed over with `done`.
  public struct Parser {
    private let folder: String
    /// Text that might be the start of a tag, kept until the next piece decides.
    private var pending = ""
    private var inBlock = false
    private var block = ""
    private var replacement: String?
    private var shownThisTurn = false

    public init(folder: String) { self.folder = folder }

    public mutating func feed(_ line: String) -> [Event] {
      guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            let type = object["type"] as? String else { return [] }
      switch type {
      case "stream_event":
        guard let event = object["event"] as? [String: Any] else { return [] }
        if event["type"] as? String == "content_block_start",
           (event["content_block"] as? [String: Any])?["type"] as? String == "text", shownThisTurn {
          return text("\n\n")
        }
        if event["type"] as? String == "content_block_delta",
           let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
           let piece = delta["text"] as? String {
          return text(piece)
        }
        return []
      case "assistant":
        let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        return content.filter { $0["type"] as? String == "tool_use" }.map { .tool(label(for: $0)) }
      case "result":
        return finish(object)
      default:
        return []
      }
    }

    private mutating func text(_ piece: String) -> [Event] {
      var rest = pending + piece
      pending = ""
      var shown = ""
      while true {
        if inBlock {
          if let close = rest.range(of: InlineAsk.closeTag) {
            block += rest[..<close.lowerBound]
            if replacement == nil { replacement = InlineAsk.trimmedBlock(block) }
            inBlock = false
            rest = String(rest[close.upperBound...])
            continue
          }
          let keep = Self.partialTag(at: rest, InlineAsk.closeTag)
          block += rest.dropLast(keep)
          pending = String(rest.suffix(keep))
          break
        }
        if let open = rest.range(of: InlineAsk.openTag) {
          shown += rest[..<open.lowerBound]
          inBlock = true
          block = ""
          rest = String(rest[open.upperBound...])
          continue
        }
        let keep = Self.partialTag(at: rest, InlineAsk.openTag)
        shown += rest.dropLast(keep)
        pending = String(rest.suffix(keep))
        break
      }
      guard !shown.isEmpty else { return [] }
      shownThisTurn = true
      return [.text(shown)]
    }

    /// How many characters at the end of `text` could begin `tag`.
    private static func partialTag(at text: String, _ tag: String) -> Int {
      for count in stride(from: min(tag.count - 1, text.count), through: 1, by: -1)
      where text.hasSuffix(tag.prefix(count)) { return count }
      return 0
    }

    private mutating func finish(_ result: [String: Any]) -> [Event] {
      var events: [Event] = []
      if !inBlock, !pending.isEmpty { events.append(.text(pending)) }
      if inBlock, replacement == nil { replacement = InlineAsk.trimmedBlock(block + pending) }
      if result["is_error"] as? Bool == true {
        let message = (result["result"] as? String).flatMap { $0.isEmpty ? nil : $0 }
          ?? (result["errors"] as? [String])?.joined(separator: "\n")
          ?? "Claude Code failed."
        events.append(.failed(message))
      } else {
        events.append(.done(replacement: replacement ?? (result["result"] as? String).flatMap(InlineAsk.replacement(in:))))
      }
      pending = ""
      inBlock = false
      block = ""
      replacement = nil
      shownThisTurn = false
      return events
    }

    private func label(for tool: [String: Any]) -> String {
      let input = tool["input"] as? [String: Any] ?? [:]
      let name = tool["name"] as? String ?? "a tool"
      switch name {
      case "Read":
        let path = input["file_path"] as? String ?? ""
        let shown = path.hasPrefix(folder + "/") ? String(path.dropFirst(folder.count + 1)) : path
        return "Reading \(shown)…"
      case "Grep": return "Searching for “\(input["pattern"] as? String ?? "")”…"
      case "Glob": return "Finding \(input["pattern"] as? String ?? "files")…"
      default: return "Using \(name)…"
      }
    }
  }
}
