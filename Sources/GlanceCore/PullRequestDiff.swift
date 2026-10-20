import Foundation

/// A pull request's or a commit's changes, from a unified diff (`gh pr diff`, or the commits API's diff), for the Files
/// page (spec 2026-10-07-pr-manager-design.md, "Pages → Files"): its files with their hunks and numbered lines, the
/// split view's pairs, and the side bar's folders.
public enum PullRequestDiff {
  public struct Line: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case context, added, removed }

    public let kind: Kind
    public let text: String
    /// Its number in the old file (context and removed lines).
    public let old: Int?
    /// Its number in the new file (context and added lines).
    public let new: Int?
    /// "\ No newline at end of file" follows it.
    public var noNewline: Bool

    public init(kind: Kind, text: String, old: Int?, new: Int?, noNewline: Bool = false) {
      self.kind = kind
      self.text = text
      self.old = old
      self.new = new
      self.noNewline = noNewline
    }
  }

  public struct Hunk: Equatable, Sendable {
    /// "@@ -10,7 +10,7 @@ struct RazorTabView: View {"
    public let header: String
    public var lines: [Line]
  }

  public struct File: Equatable, Sendable {
    public enum Change: Equatable, Sendable { case added, deleted, modified, renamed }

    /// Where it is now (where it was, for a deleted file).
    public let path: String
    /// Where it was before a rename.
    public let oldPath: String?
    public let change: Change
    public let isBinary: Bool
    /// Its mode before and after, when only that changed or that too ("100644", "100755").
    public let oldMode: String?
    public let newMode: String?
    public let hunks: [Hunk]

    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count } }
    /// More than 1,500 changed lines: the page folds it until it's opened.
    public var isLarge: Bool { additions + deletions > 1_500 }
  }

  /// A row of the split view: the old side's line and the new side's.
  public struct Row: Equatable, Sendable {
    public let left: Line?
    public let right: Line?
  }

  /// The side bar's folder ("scripts/", or "./" for the root) and its files' paths.
  public struct Folder: Equatable, Sendable {
    public let path: String
    public let files: [String]
  }

  public static func arguments(number: Int, repository: String) -> [String] {
    ["pr", "diff", String(number), "--repo", repository]
  }

  /// One commit's changes, as a diff, from the commits API.
  public static func commitArguments(sha: String, repository: String) -> [String] {
    ["api", "repos/\(repository)/commits/\(sha)", "-H", "Accept: application/vnd.github.diff"]
  }

  /// The files of a unified diff, in its order. A hunk takes exactly the lines its header counts; a CR before a line's
  /// end goes.
  public static func parse(_ text: String) -> [File] {
    var files: [File] = []
    var builder: Builder?
    var oldNumber = 0, newNumber = 0, oldLeft = 0, newLeft = 0
    // Split on "\n" itself: Swift reads "\r\n" as one Character, so a CRLF line would swallow the next one.
    for raw in text.components(separatedBy: "\n") {
      var line = raw
      if line.hasSuffix("\r") { line.removeLast() }
      if line.hasPrefix("diff --git ") {
        if let file = builder?.file { files.append(file) }
        builder = Builder(header: String(line.dropFirst("diff --git ".count)))
        oldLeft = 0
        newLeft = 0
        continue
      }
      guard builder != nil else { continue }
      if line.hasPrefix("\\") {
        builder?.markNoNewline()
      } else if oldLeft > 0 || newLeft > 0 {
        let text = String(line.dropFirst())
        switch line.first {
        case "+":
          builder?.append(Line(kind: .added, text: text, old: nil, new: newNumber))
          newNumber += 1
          newLeft -= 1
        case "-":
          builder?.append(Line(kind: .removed, text: text, old: oldNumber, new: nil))
          oldNumber += 1
          oldLeft -= 1
        default:
          builder?.append(Line(kind: .context, text: text, old: oldNumber, new: newNumber))
          oldNumber += 1
          newNumber += 1
          oldLeft -= 1
          newLeft -= 1
        }
      } else if let range = hunkRange(line) {
        builder?.hunks.append(Hunk(header: line, lines: []))
        (oldNumber, oldLeft, newNumber, newLeft) = (range.oldStart, range.oldCount, range.newStart, range.newCount)
      } else {
        builder?.read(line)
      }
    }
    if let file = builder?.file { files.append(file) }
    return files
  }

  /// The split view: a context line on both sides; removed lines beside the added lines that follow them, row by row.
  public static func rows(_ hunk: Hunk) -> [Row] {
    var rows: [Row] = []
    var removed: [Line] = [], added: [Line] = []
    func pairUp() {
      for index in 0..<max(removed.count, added.count) {
        rows.append(Row(left: index < removed.count ? removed[index] : nil,
                        right: index < added.count ? added[index] : nil))
      }
      removed = []
      added = []
    }
    for line in hunk.lines {
      switch line.kind {
      case .context:
        pairUp()
        rows.append(Row(left: line, right: line))
      case .removed:
        if !added.isEmpty { pairUp() }
        removed.append(line)
      case .added:
        added.append(line)
      }
    }
    pairUp()
    return rows
  }

  /// The side bar's folders: each file under its folder, folders in the diff's order with the root's last.
  public static func folders(_ paths: [String]) -> [Folder] {
    var order: [String] = []
    var files: [String: [String]] = [:]
    for path in paths {
      let folder = path.lastIndex(of: "/").map { String(path[...$0]) } ?? "./"
      if files[folder] == nil { order.append(folder) }
      files[folder, default: []].append(path)
    }
    let sorted = order.filter { $0 != "./" } + order.filter { $0 == "./" }
    return sorted.map { Folder(path: $0, files: files[$0] ?? []) }
  }

  /// The new file's lines `from`...`to` that the diff shows: what a suggestion on them replaces.
  public static func newLines(_ file: File, from: Int, to: Int) -> [String] {
    file.hunks.flatMap(\.lines).compactMap { line in
      guard let new = line.new, new >= from, new <= to else { return nil }
      return line.text
    }
  }

  // MARK: Reading

  /// "@@ -10,7 +12 @@ name": where each side starts and how many lines it has (1 when the count is left out).
  static func hunkRange(_ header: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
    let parts = header.split(separator: " ", maxSplits: 3)
    guard parts.count >= 3, parts[0] == "@@", parts[1].hasPrefix("-"), parts[2].hasPrefix("+"),
      let old = span(parts[1].dropFirst()), let new = span(parts[2].dropFirst()) else { return nil }
    return (old.start, old.count, new.start, new.count)
  }

  private static func span(_ text: Substring) -> (start: Int, count: Int)? {
    let numbers = text.split(separator: ",", omittingEmptySubsequences: false)
    guard let first = numbers.first, let start = Int(first) else { return nil }
    if numbers.count == 1 { return (start, 1) }
    guard numbers.count == 2, let count = Int(numbers[1]) else { return nil }
    return (start, count)
  }

  /// The rest of `line` after `prefix`, when it starts with it.
  static func value(_ line: String, after prefix: String) -> String? {
    line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
  }

  /// A path on a "---" or "+++" line, without its a/ or b/ and the tab git puts after a name with a space; nil for
  /// /dev/null.
  static func diffPath(_ text: String) -> String? {
    var text = text
    while text.hasSuffix("\t") { text.removeLast() }
    if text == "/dev/null" { return nil }
    return stripSide(unquote(text))
  }

  static func stripSide(_ path: String) -> String {
    path.hasPrefix("a/") || path.hasPrefix("b/") ? String(path.dropFirst(2)) : path
  }

  /// The new path on a "diff --git a/x b/x" line, for a file with no "+++" line (binary, a pure rename, a mode change).
  /// Without a rename both halves are the same path, whatever spaces it has.
  static func headerPath(_ header: String) -> String {
    if header.hasSuffix("\""), let start = header.range(of: " \"", options: .backwards) {
      return stripSide(unquote(String(header[header.index(after: start.lowerBound)...])))
    }
    let count = header.count
    if count > 5, (count - 5) % 2 == 0, header.hasPrefix("a/") {
      let half = (count - 5) / 2
      let old = header.dropFirst(2).prefix(half)
      let new = header.suffix(half)
      if old == new { return String(new) }
    }
    if let range = header.range(of: " b/") { return String(header[range.upperBound...]) }
    return header
  }

  /// A path git quoted ("a/caf\303\251.txt"): its escapes and octal bytes back to text. Anything else comes back as
  /// it is.
  static func unquote(_ text: String) -> String {
    guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return text }
    let inner = Array(text.utf8.dropFirst().dropLast())
    var bytes: [UInt8] = []
    var index = 0
    while index < inner.count {
      let byte = inner[index]
      guard byte == UInt8(ascii: "\\"), index + 1 < inner.count else {
        bytes.append(byte)
        index += 1
        continue
      }
      let next = inner[index + 1]
      switch next {
      case UInt8(ascii: "n"):
        bytes.append(10)
        index += 2
      case UInt8(ascii: "t"):
        bytes.append(9)
        index += 2
      case UInt8(ascii: "0")...UInt8(ascii: "7"):
        var value = 0, length = 0
        while length < 3, index + 1 + length < inner.count,
          (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(inner[index + 1 + length]) {
          value = value * 8 + Int(inner[index + 1 + length] - UInt8(ascii: "0"))
          length += 1
        }
        bytes.append(UInt8(truncatingIfNeeded: value))
        index += 1 + length
      default:
        bytes.append(next)
        index += 2
      }
    }
    return String(decoding: bytes, as: UTF8.self)
  }

  /// One file while its lines are read.
  private struct Builder {
    var path: String
    var oldPath: String?
    var change = File.Change.modified
    var isBinary = false
    var oldMode: String?
    var newMode: String?
    var hunks: [Hunk] = []
    var renamed = false
    /// The "---" line's path: where a deleted file was.
    var minus: String?

    init(header: String) {
      path = PullRequestDiff.headerPath(header)
    }

    mutating func append(_ line: Line) {
      guard let last = hunks.indices.last else { return }
      hunks[last].lines.append(line)
    }

    mutating func markNoNewline() {
      guard let last = hunks.indices.last, !hunks[last].lines.isEmpty else { return }
      hunks[last].lines[hunks[last].lines.count - 1].noNewline = true
    }

    mutating func read(_ line: String) {
      if PullRequestDiff.value(line, after: "new file mode ") != nil {
        change = .added
      } else if PullRequestDiff.value(line, after: "deleted file mode ") != nil {
        change = .deleted
      } else if let mode = PullRequestDiff.value(line, after: "old mode ") {
        oldMode = mode
      } else if let mode = PullRequestDiff.value(line, after: "new mode ") {
        newMode = mode
      } else if let from = PullRequestDiff.value(line, after: "rename from ") {
        oldPath = PullRequestDiff.unquote(from)
        renamed = true
      } else if let to = PullRequestDiff.value(line, after: "rename to ") {
        path = PullRequestDiff.unquote(to)
        renamed = true
      } else if let old = PullRequestDiff.value(line, after: "--- ") {
        minus = PullRequestDiff.diffPath(old)
      } else if let new = PullRequestDiff.value(line, after: "+++ ") {
        if let new = PullRequestDiff.diffPath(new) { path = new }
      } else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
        isBinary = true
      }
    }

    var file: File {
      File(path: change == .deleted ? (minus ?? path) : path,
           oldPath: renamed ? oldPath : nil,
           change: renamed && change == .modified ? .renamed : change,
           isBinary: isBinary,
           oldMode: oldMode,
           newMode: newMode,
           hunks: hunks)
    }
  }
}
