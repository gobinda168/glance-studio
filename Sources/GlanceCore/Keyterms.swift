import Foundation

/// Words Scribe should favour: names from Claude's last reply, files in the project, and a few constants.
public enum Keyterms {
  public static let limit = 50
  /// Scribe rejects the whole session if any keyterm is longer than this.
  public static let maxLength = 20
  public static let builtIn = ["Claude", "Claude Code", "Mermaid", "Warp", "Glance", "Swift", "SwiftUI",
                               "TypeScript", "React"]

  /// `projectFiles` are repo-relative paths, most relevant first.
  public static func build(reply: String?, projectFiles: [String]) -> [String] {
    var terms: [String] = []
    var seen = Set<String>()
    func add(_ term: String?) {
      guard var term else { return }
      // `PanelStateTests.swift` is too long, but `PanelStateTests` is what gets said anyway.
      if term.count > maxLength, let dot = term.lastIndex(of: "."), dot > term.startIndex { term = String(term[..<dot]) }
      guard (3...maxLength).contains(term.count), seen.insert(term.lowercased()).inserted else { return }
      terms.append(term)
    }
    for code in inlineCode(reply ?? "") { add(name(fromCode: code)) }
    for path in projectFiles { add(path.split(separator: "/").last.map(String.init)) }
    for term in builtIn { add(term) }
    return Array(terms.prefix(limit))
  }

  private static func inlineCode(_ markdown: String) -> [String] {
    let regex = try! NSRegularExpression(pattern: "`([^`\\n]+)`")
    let range = NSRange(markdown.startIndex..., in: markdown)
    return regex.matches(in: markdown, range: range).compactMap { Range($0.range(at: 1), in: markdown).map { String(markdown[$0]) } }
  }

  /// `src/a/b.ts` → `b.ts`, `foo()` → `foo`; commands (anything with a space) are skipped.
  private static func name(fromCode code: String) -> String? {
    var name = code.trimmingCharacters(in: .whitespaces)
    guard !name.contains(" ") else { return nil }
    if let last = name.split(separator: "/").last { name = String(last) }
    if let paren = name.firstIndex(of: "(") { name = String(name[..<paren]) }
    return name
  }
}
