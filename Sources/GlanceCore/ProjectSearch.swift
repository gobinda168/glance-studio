import Foundation

public struct SearchOptions: Equatable, Sendable {
  public var caseSensitive: Bool
  public var wholeWord: Bool
  public var regex: Bool

  public init(caseSensitive: Bool = false, wholeWord: Bool = false, regex: Bool = false) {
    self.caseSensitive = caseSensitive
    self.wholeWord = wholeWord
    self.regex = regex
  }
}

/// One match. `column` is 1-based and `length` is in UTF-16 units (Monaco's unit); `preview` is the line, trimmed and
/// windowed, and `previewStart` is where the match starts inside it (0-based, UTF-16).
public struct SearchMatch: Equatable, Sendable {
  public var path: String
  public var line: Int
  public var column: Int
  public var length: Int
  public var preview: String
  public var previewStart: Int
}

public struct SearchResult: Equatable, Sendable {
  public var matches: [SearchMatch]
  public var truncated: Bool
  public var fileCount: Int
}

public struct ReplaceFailure: Equatable, Sendable {
  public var path: String
  public var message: String
}

public struct ReplaceResult: Equatable, Sendable {
  public var replacements: Int
  public var files: Int
  /// Files left alone on request (unsaved edits in the editor).
  public var skipped: [String]
  public var failed: [ReplaceFailure]
}

public enum SearchError: Error, Equatable {
  case emptyQuery
  case invalidPattern(String)
  case matchesEmpty
  case cancelled

  public var code: String {
    switch self {
    case .emptyQuery: "empty-query"
    case .invalidPattern: "invalid-pattern"
    case .matchesEmpty: "matches-empty"
    case .cancelled: "cancelled"
    }
  }

  public var message: String {
    switch self {
    case .emptyQuery: "Type something to search for."
    case .invalidPattern(let reason): "Invalid regular expression: \(reason)"
    case .matchesEmpty: "That pattern can match empty text, so replacing would change every position."
    case .cancelled: "Cancelled."
    }
  }
}

/// A flag a long scan checks, so a newer search can stop an older one.
public final class CancellationToken: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  public init() {}

  public var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  public func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
}

public enum ProjectSearch {
  /// The pattern for a query: literal text is escaped, whole-word wraps it in word boundaries, and case is ignored
  /// unless asked for.
  public static func makeRegex(query: String, options: SearchOptions) throws -> NSRegularExpression {
    guard !query.isEmpty else { throw SearchError.emptyQuery }
    var pattern = options.regex ? query : NSRegularExpression.escapedPattern(for: query)
    if options.wholeWord { pattern = "\\b(?:\(pattern))\\b" }
    var flags: NSRegularExpression.Options = [.anchorsMatchLines]
    if !options.caseSensitive { flags.insert(.caseInsensitive) }
    do {
      return try NSRegularExpression(pattern: pattern, options: flags)
    } catch {
      throw SearchError.invalidPattern(error.localizedDescription)
    }
  }

  /// Every non-empty match in `text`, line by line (any line ending), up to `limit`.
  public static func matches(in text: String, path: String, regex: NSRegularExpression, limit: Int) -> [SearchMatch] {
    var found: [SearchMatch] = []
    guard limit > 0 else { return found }
    var lineNumber = 0
    text.enumerateLines { line, stop in
      lineNumber += 1
      let length = (line as NSString).length
      for match in regex.matches(in: line, range: NSRange(location: 0, length: length)) where match.range.length > 0 {
        let preview = preview(line: line, start: match.range.location, length: match.range.length)
        found.append(SearchMatch(path: path, line: lineNumber, column: match.range.location + 1, length: match.range.length,
                                 preview: preview.text, previewStart: preview.start))
        if found.count >= limit { stop = true; return }
      }
    }
    return found
  }

  /// The line without its indentation, cut to about 240 units around the match.
  public static func preview(line: String, start: Int, length: Int) -> (text: String, start: Int) {
    let ns = line as NSString
    var from = 0
    while from < start, from < ns.length, [0x20, 0x09].contains(ns.character(at: from)) { from += 1 }
    if start - from > 60 { from = start - 60 }
    let to = min(ns.length, from + 240)
    return (ns.substring(with: NSRange(location: from, length: to - from)), start - from)
  }
}
