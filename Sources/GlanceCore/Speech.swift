import Foundation

/// Turns markdown blocks into text that sounds natural read aloud.
public enum Speech {
  /// What the voice should say for a block, or nil for blocks that are only shown (code, diagrams, tables).
  public static func text(for block: Block) -> String? {
    let spoken: String
    switch block.kind {
    case .code, .mermaid, .table, .rule:
      return nil
    case .heading:
      spoken = sentence(clean(String(block.markdown.drop { $0 == "#" })))
    case .paragraph:
      spoken = clean(block.markdown)
    case .quote:
      spoken = clean(block.markdown.split(separator: "\n").map { $0.drop { $0 == ">" || $0 == " " } }.joined(separator: " "))
    case .list:
      spoken = listItems(block.markdown).map { sentence(clean($0)) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
    return spoken.isEmpty ? nil : spoken
  }

  /// List items with their continuation lines folded in, markers removed.
  private static func listItems(_ markdown: String) -> [String] {
    var items: [String] = []
    for line in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
      let line = String(line)
      if Blocks.isListItem(line) {
        items.append(String(line.drop { $0 == " " }.drop { $0.isNumber || "-*+.)".contains($0) }))
      } else if !items.isEmpty {
        items[items.count - 1] += " " + line
      }
    }
    return items
  }

  private static func sentence(_ text: String) -> String {
    guard let first = text.first else { return text }
    let capitalized = first.uppercased() + text.dropFirst()
    return ".!?:;".contains(capitalized.last!) ? capitalized : capitalized + "."
  }

  static func clean(_ markdown: String) -> String {
    var s = markdown.replacingOccurrences(of: "\n", with: " ")
    s = replace(#"!\[[^\]]*\]\([^)]*\)"#, in: s, with: "")
    s = replace(#"\[([^\]]+)\]\([^)]*\)"#, in: s, with: "$1")
    s = replace(#"`([^`]+)`"#, in: s) { simplifyCode($0[1]) }
    s = replace(#"https?://\S+"#, in: s, with: "")
    s = replace(#"</?[A-Za-z][^>]*>"#, in: s, with: "")
    s = replace(#"\*\*(.+?)\*\*"#, in: s, with: "$1")
    s = replace(#"(?<!\w)__(.+?)__(?!\w)"#, in: s, with: "$1")
    s = replace(#"~~(.+?)~~"#, in: s, with: "$1")
    s = replace(#"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"#, in: s, with: "$1")
    s = replace(#"(?<!\w)_(?!\s)(.+?)(?<!\s)_(?!\w)"#, in: s, with: "$1")
    for arrow in ["→", "⟶", "->", "=>"] { s = s.replacingOccurrences(of: arrow, with: " to ") }
    s = replace(#"\s+"#, in: s, with: " ")
    s = replace(#" ([.,;:!?])"#, in: s, with: "$1")
    return s.trimmingCharacters(in: .whitespaces)
  }

  /// Inline code is read by name: paths become their file name, calls lose their parentheses,
  /// and anything long or command-like becomes a short reference.
  private static func simplifyCode(_ code: String) -> String {
    let code = code.trimmingCharacters(in: .whitespaces)
    if code.contains(" ") { return code.count > 24 ? "that command" : code }
    var name = code
    if name.contains("/"), let last = name.split(separator: "/").last { name = String(last) }
    name = replace(#"\(.*\)$"#, in: name, with: "")
    return name.count > 40 ? "that snippet" : name
  }

  private static func replace(_ pattern: String, in s: String, with template: String) -> String {
    let regex = try! NSRegularExpression(pattern: pattern)
    return regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
  }

  private static func replace(_ pattern: String, in s: String, transform: ([String]) -> String) -> String {
    let regex = try! NSRegularExpression(pattern: pattern)
    var result = ""
    var cursor = s.startIndex
    for match in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
      let range = Range(match.range, in: s)!
      let groups = (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: s).map { String(s[$0]) } ?? "" }
      result += s[cursor..<range.lowerBound] + transform(groups)
      cursor = range.upperBound
    }
    return result + s[cursor...]
  }
}
