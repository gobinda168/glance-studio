import Foundation

/// HTML comments in Markdown (spec 2026-10-12-pr-sidebar-tabs-design.md, "Description"): GitHub hides them, and pull
/// request templates are full of them, so the PR pages take them out before rendering.
public enum MarkdownComments {
  /// `markdown` without its `<!-- … -->` comments, over lines too. A line left blank by its comment goes; fenced code
  /// keeps everything.
  public static func strip(_ markdown: String) -> String {
    var lines: [String] = []
    var fenced = false
    var commented = false
    for line in markdown.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if !commented, trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        fenced.toggle()
        lines.append(line)
        continue
      }
      if fenced {
        lines.append(line)
        continue
      }
      var rest = Substring(line)
      var kept = ""
      var touched = commented
      while true {
        if commented {
          guard let end = rest.range(of: "-->") else { break }
          rest = rest[end.upperBound...]
          commented = false
        }
        guard let start = rest.range(of: "<!--") else {
          kept += rest
          break
        }
        kept += rest[..<start.lowerBound]
        rest = rest[start.upperBound...]
        commented = true
        touched = true
      }
      if touched && kept.trimmingCharacters(in: .whitespaces).isEmpty { continue }
      lines.append(kept)
    }
    return lines.joined(separator: "\n")
  }
}
