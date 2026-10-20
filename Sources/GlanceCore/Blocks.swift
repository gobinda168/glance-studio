import Foundation

/// One top-level markdown block. The panel renders and narrates a reply block by block,
/// so the spoken paragraph can be highlighted and diagrams revealed next to their prose.
public struct Block: Equatable, Sendable, Codable {
  public enum Kind: String, Sendable, Codable {
    case paragraph, heading, list, quote, code, mermaid, table, rule
  }

  public var kind: Kind
  /// The block's markdown; for code and mermaid blocks, the fence's contents only.
  public var markdown: String
  /// The fence's info string (first word), for code blocks.
  public var lang: String?

  public init(kind: Kind, markdown: String, lang: String? = nil) {
    self.kind = kind
    self.markdown = markdown
    self.lang = lang
  }
}

public enum Blocks {
  public static func split(_ markdown: String) -> [Block] {
    let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    var blocks: [Block] = []
    var i = 0
    while i < lines.count {
      let line = lines[i]
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty {
        i += 1
      } else if let fence = fenceMarker(trimmed) {
        let lang = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
          .split(separator: " ").first.map(String.init)
        var body: [String] = []
        i += 1
        while i < lines.count, !closesFence(lines[i], fence) {
          body.append(lines[i])
          i += 1
        }
        i += 1 // closing fence
        let isMermaid = lang?.lowercased() == "mermaid"
        blocks.append(Block(kind: isMermaid ? .mermaid : .code, markdown: body.joined(separator: "\n"),
                            lang: isMermaid ? nil : lang))
      } else if isHeading(trimmed) {
        blocks.append(Block(kind: .heading, markdown: trimmed))
        i += 1
      } else if isRule(trimmed) {
        blocks.append(Block(kind: .rule, markdown: trimmed))
        i += 1
      } else if trimmed.hasPrefix("|") {
        let end = runEnd(lines, from: i) { $0.trimmingCharacters(in: .whitespaces).hasPrefix("|") }
        blocks.append(Block(kind: .table, markdown: lines[i..<end].joined(separator: "\n")))
        i = end
      } else if trimmed.hasPrefix(">") {
        let end = runEnd(lines, from: i) { $0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
        blocks.append(Block(kind: .quote, markdown: lines[i..<end].joined(separator: "\n")))
        i = end
      } else if isListItem(line) {
        var end = i + 1
        while end < lines.count {
          let next = lines[end]
          if isListItem(next) || (next.first == " " || next.first == "\t") && !next.trimmingCharacters(in: .whitespaces).isEmpty {
            end += 1
          } else if next.trimmingCharacters(in: .whitespaces).isEmpty, end + 1 < lines.count, isListItem(lines[end + 1]) {
            end += 1
          } else {
            break
          }
        }
        blocks.append(Block(kind: .list, markdown: lines[i..<end].joined(separator: "\n")))
        i = end
      } else {
        var end = i + 1
        while end < lines.count, startsParagraphContinuation(lines[end]) { end += 1 }
        blocks.append(Block(kind: .paragraph, markdown: lines[i..<end].joined(separator: "\n")))
        i = end
      }
    }
    return blocks
  }

  private static func fenceMarker(_ trimmed: String) -> String? {
    for char in ["`", "~"] where trimmed.hasPrefix(String(repeating: char, count: 3)) {
      return String(trimmed.prefix { String($0) == char })
    }
    return nil
  }

  private static func closesFence(_ line: String, _ fence: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.hasPrefix(fence) && trimmed.allSatisfy { String($0) == String(fence.first!) }
  }

  private static func isHeading(_ trimmed: String) -> Bool {
    let hashes = trimmed.prefix { $0 == "#" }.count
    return (1...6).contains(hashes) && trimmed.dropFirst(hashes).first == " "
  }

  private static func isRule(_ trimmed: String) -> Bool {
    let compact = trimmed.replacingOccurrences(of: " ", with: "")
    guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
    return compact.allSatisfy { $0 == first }
  }

  static func isListItem(_ line: String) -> Bool {
    let trimmed = line.drop { $0 == " " }
    if let first = trimmed.first, "-*+".contains(first) { return trimmed.dropFirst().first == " " }
    let digits = trimmed.prefix { $0.isNumber }
    guard !digits.isEmpty, digits.count <= 9 else { return false }
    let rest = trimmed.dropFirst(digits.count)
    return (rest.first == "." || rest.first == ")") && rest.dropFirst().first == " "
  }

  private static func startsParagraphContinuation(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return !trimmed.isEmpty && fenceMarker(trimmed) == nil && !isHeading(trimmed) && !isRule(trimmed)
      && !trimmed.hasPrefix("|") && !trimmed.hasPrefix(">") && !isListItem(line)
  }

  private static func runEnd(_ lines: [String], from start: Int, while matches: (String) -> Bool) -> Int {
    var end = start
    while end < lines.count, matches(lines[end]) { end += 1 }
    return end
  }
}
