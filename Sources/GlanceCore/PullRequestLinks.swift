import Foundation

/// Links on the PR pages stay in Glance (spec 2026-10-07-pr-manager-design.md, "In the app only"): `#N` references
/// become links Glance opens, and github.com links to this repository's pull requests and issues open as tabs. Links
/// to anywhere else go to the browser.
public enum PullRequestLinks {
  public enum Target: Equatable, Sendable {
    /// A pull request or an issue of this repository (GitHub numbers them together).
    case number(Int)
    /// Anywhere else.
    case external(URL)
  }

  /// The scheme `autolink` gives `#N`.
  public static let scheme = "glance-ref"

  /// `markdown` with each `#N` made a link (`glance-ref:N`), except inside code (fenced blocks, `spans`) and inside
  /// links already written.
  public static func autolink(_ markdown: String) -> String {
    var fenced = false
    var lines: [String] = []
    for line in markdown.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        fenced.toggle()
        lines.append(line)
      } else if fenced {
        lines.append(line)
      } else {
        // Between backticks (the odd pieces) is code.
        let pieces = line.components(separatedBy: "`").enumerated().map { index, piece in
          index.isMultiple(of: 2) ? link(piece) : piece
        }
        lines.append(pieces.joined(separator: "`"))
      }
    }
    return lines.joined(separator: "\n")
  }

  public static func target(_ url: URL, repository: String) -> Target {
    if url.scheme == scheme, let number = Int(url.absoluteString.dropFirst(scheme.count + 1)) { return .number(number) }
    if let host = url.host?.lowercased(), host == "github.com" || host == "www.github.com" {
      let parts = url.path.split(separator: "/").map(String.init)
      if parts.count >= 4, "\(parts[0])/\(parts[1])".lowercased() == repository.lowercased(),
         parts[2] == "pull" || parts[2] == "issues", let number = Int(parts[3]) {
        return .number(number)
      }
    }
    return .external(url)
  }

  /// `#N` after the start, a space, "(" or punctuation, and ending at a word boundary. Not after "[" (a link's text)
  /// or a letter ("abc#12").
  private static func link(_ text: String) -> String {
    text.replacingOccurrences(of: #"(^|[\s(,;:])#(\d+)\b"#, with: "$1[#$2](\(scheme):$2)", options: .regularExpression)
  }
}
