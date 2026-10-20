import Foundation

/// A Claude Code transcript (or the part after `coveredBytes`) cut down for the summarizer (spec
/// 2026-10-11-humanize-summaries-design.md, "Summary engine"): the user's prompts, Claude's text, one line per tool
/// call. Tool output and file contents are left out, which makes it about a tenth the size. Only complete lines count:
/// a line Claude Code is still writing is left for the next digest.
public struct TranscriptDigest: Equatable, Sendable {
  public var text: String
  /// Prompts in this part.
  public var turns: Int
  /// Bytes of the input read, up to and including the last newline.
  public var coveredBytes: Int
  /// This part's first prompt, for a session's title.
  public var firstPrompt: String?

  public init(text: String, turns: Int, coveredBytes: Int, firstPrompt: String?) {
    self.text = text
    self.turns = turns
    self.coveredBytes = coveredBytes
    self.firstPrompt = firstPrompt
  }

  public static func make(data: Data, root: String?) -> TranscriptDigest {
    let bytes = [UInt8](data)
    guard let lastNewline = bytes.lastIndex(of: UInt8(ascii: "\n")) else {
      return TranscriptDigest(text: "", turns: 0, coveredBytes: 0, firstPrompt: nil)
    }
    let jsonl = String(decoding: bytes[...lastNewline], as: UTF8.self)
    var lines: [String] = []
    var turns = 0
    var firstPrompt: String?
    for item in ChatTranscript.thread(jsonl: jsonl, root: root).items {
      switch item {
      case .user(let text, _):
        turns += 1
        if firstPrompt == nil { firstPrompt = text }
        lines.append((lines.isEmpty ? "" : "\n") + "USER: " + text)
      case .assistant(let blocks):
        lines.append("CLAUDE: " + blocks.map(\.markdown).joined(separator: "\n"))
      case .tool(let name, let detail):
        lines.append("· \(name) \(detail)")
      case .denied(let name, let detail):
        lines.append("· \(name) \(detail) (refused)")
      }
    }
    return TranscriptDigest(text: lines.joined(separator: "\n"), turns: turns, coveredBytes: lastNewline + 1,
                            firstPrompt: firstPrompt)
  }

  /// `text` in pieces of at most about `limit` characters, cut only where a turn starts ("\n\nUSER: "). A single turn
  /// longer than `limit` stays whole. Joined with "\n\n" they give `text` back.
  public static func chunks(_ text: String, limit: Int) -> [String] {
    guard text.count > limit else { return [text] }
    let turns = text.components(separatedBy: "\n\nUSER: ").enumerated()
      .map { $0.offset == 0 ? $0.element : "USER: " + $0.element }
    var chunks: [String] = []
    var current = ""
    for turn in turns {
      if !current.isEmpty, current.count + 2 + turn.count > limit {
        chunks.append(current)
        current = turn
      } else {
        current = current.isEmpty ? turn : current + "\n\n" + turn
      }
    }
    if !current.isEmpty { chunks.append(current) }
    return chunks
  }
}
