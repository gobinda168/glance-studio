import Foundation

/// Ask Claude in a pull request's diff (spec 2026-10-08-pr-ask-lists-design.md, "Stage 3"): a question about a file or
/// lines selected in its diff, answered by the Inline Ask runner in review mode: questions only, nothing edited.
public enum DiffAsk {
  /// What the diff belongs to.
  public enum Subject: Equatable, Sendable {
    case pullRequest(number: Int, title: String, repository: String, head: String, base: String)
    /// New Pull Request's compare: a branch not raised yet.
    case branch(head: String, base: String)
  }

  /// The whole file, or the lines from `start` (nil: `end` alone) to `end`, as the Files page picks them.
  public enum Scope: Equatable, Sendable {
    case file
    case lines(start: ReviewThreads.Anchor?, end: ReviewThreads.Anchor)
  }

  public static let rules = """
    You are answering in a code review app, about a pull request's diff. Answer briefly in Markdown. You can read \
    files but never edit or write them, and never suggest you made a change.
    """

  /// The diff part of a message stops here.
  public static let limit = 60_000

  public static func arguments() -> [String] { InlineAsk.arguments(rules: rules) }

  /// "this file", "line 42", "lines 40–44".
  public static func place(_ scope: Scope) -> String {
    switch scope {
    case .file: return "this file"
    case .lines(let start, let end):
      guard let start, start != end else { return "line \(end.line)" }
      return "lines \(start.line)–\(end.line)"
    }
  }

  /// Where the selected lines are among the file's lines (every hunk's, in order), top first. Nil for a file, or when
  /// an end isn't in the diff (a push since).
  public static func selection(_ file: PullRequestDiff.File, _ scope: Scope) -> ClosedRange<Int>? {
    guard case .lines(let start, let end) = scope else { return nil }
    let lines = file.hunks.flatMap(\.lines)
    func index(_ anchor: ReviewThreads.Anchor) -> Int? {
      lines.firstIndex { anchor.side == .left ? $0.old == anchor.line : $0.new == anchor.line }
    }
    guard let last = index(end) else { return nil }
    guard let start else { return last...last }
    guard let first = index(start) else { return nil }
    return min(first, last)...max(first, last)
  }

  /// A box's first message: what the diff is; that the folder is a local clone, when it is; the file; the selected
  /// lines marked `>` in their hunks (or the file's whole diff), cut at `limit`; the question.
  public static func message(subject: Subject, file: PullRequestDiff.File, scope: Scope, localClone: Bool,
                             question: String) -> String {
    var lines: [String] = []
    switch subject {
    case .pullRequest(let number, let title, let repository, let head, let base):
      lines.append("Pull request #\(number) \"\(title)\" in \(repository) (\(head) → \(base)).")
    case .branch(let head, let base):
      lines.append("The branch \(head) → \(base), not yet a pull request.")
    }
    if localClone {
      lines.append("Your working folder is a local clone; it may be on another branch than this pull request.")
    }
    if file.change == .renamed, let old = file.oldPath {
      lines.append("File: \(file.path) (renamed from \(old))")
    } else {
      lines.append("File: \(file.path)")
    }
    let selected = selection(file, scope)
    switch scope {
    case .file: lines.append("The user asks about this file. Its diff:")
    case .lines where selected == nil:
      lines.append("The user asks about \(place(scope)), which isn't in the diff any more. The file's diff:")
    case .lines: lines.append("The user selected \(place(scope)) of the diff (marked >):")
    }
    lines.append("(Columns: the old line number, the new one, + added or - removed, the code.)")
    var diff: [String] = []
    var index = 0
    for hunk in file.hunks {
      let range = index..<(index + hunk.lines.count)
      index += hunk.lines.count
      if let selected, !range.overlaps(selected) { continue }
      diff.append(hunk.header)
      for (offset, line) in hunk.lines.enumerated() {
        diff.append(format(line, marked: selected?.contains(range.lowerBound + offset) ?? false))
      }
    }
    var code = diff.isEmpty ? "(No lines changed: a binary file, or a rename or mode change only.)"
      : diff.joined(separator: "\n")
    if code.count > limit { code = String(code.prefix(limit)) + "\n[diff cut]" }
    return (lines + [code, "", "Question: \(question)"]).joined(separator: "\n")
  }

  /// ">   11    11 + code": `>` on a selected line, the numbers right-aligned in five columns, the sign, the code.
  static func format(_ line: PullRequestDiff.Line, marked: Bool) -> String {
    func number(_ value: Int?) -> String {
      let text = value.map(String.init) ?? ""
      return String(repeating: " ", count: max(0, 5 - text.count)) + text
    }
    let sign = line.kind == .added ? "+" : line.kind == .removed ? "-" : " "
    return "\(marked ? ">" : " ")\(number(line.old)) \(number(line.new)) \(sign) \(line.text)"
  }
}
