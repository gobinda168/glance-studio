import Foundation

/// A file mentioned in terminal output: `src/App.swift`, `src/App.swift:12`, `src/App.swift:12:5`.
public struct PathLink: Equatable, Sendable {
  public var path: String
  public var line: Int?
  public var column: Int?

  public init(path: String, line: Int?, column: Int?) {
    self.path = path
    self.line = line
    self.column = column
  }
}

public enum PathLinks {
  private static let position = try! NSRegularExpression(pattern: #"^(.*?):(\d+)(?::(\d+))?:?$"#)
  /// A GitHub-style anchor, as Claude's markdown links write positions: `#L12`, `#L12C5`, `#L12-L20`.
  private static let anchor = try! NSRegularExpression(pattern: #"^(.+?)#L(\d+)(?:C(\d+))?(?:-L?\d+(?:C\d+)?)?$"#)

  /// Splits a trailing `:line`, `:line:column` or `#Lline` anchor off the path, and turns a `file://` URL (as
  /// hyperlinks carry it: percent-encoded, maybe naming localhost) into its path. Colons that don't precede digits
  /// stay in the path, and a line of 0 isn't a line.
  public static func parse(_ text: String) -> PathLink {
    var text = text
    if text.hasPrefix("file://") {
      text.removeFirst("file://".count)
      if text.hasPrefix("localhost/") { text.removeFirst("localhost".count) }
      text = text.removingPercentEncoding ?? text
    }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = anchor.firstMatch(in: text, range: range) ?? position.firstMatch(in: text, range: range),
          let path = Range(match.range(at: 1), in: text) else {
      return PathLink(path: text, line: nil, column: nil)
    }
    func number(_ group: Int) -> Int? {
      Range(match.range(at: group), in: text).flatMap { Int(text[$0]) }.flatMap { $0 > 0 ? $0 : nil }
    }
    return PathLink(path: String(text[path]), line: number(2), column: number(3))
  }

  /// An absolute, normalised path: `path` itself when absolute (or `~`), else `path` inside `directory`. Nil when a
  /// relative path has no folder to be relative to.
  public static func resolve(_ path: String, relativeTo directory: String?, home: String = NSHomeDirectory()) -> String? {
    if path.hasPrefix("/") || path.hasPrefix("~") { return SessionMatch.normalize(path, home: home) }
    guard let directory, !directory.isEmpty else { return nil }
    let base = SessionMatch.normalize(directory, home: home)
    return SessionMatch.normalize(base + "/" + path, home: home)
  }

  /// `absolute` relative to `root`, or nil when it isn't strictly inside it. Both must already be normalised.
  public static func relative(_ absolute: String, inRoot root: String) -> String? {
    let prefix = root.hasSuffix("/") ? root : root + "/"
    guard absolute.hasPrefix(prefix), absolute.count > prefix.count else { return nil }
    return String(absolute.dropFirst(prefix.count))
  }
}
