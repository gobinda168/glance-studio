import Foundation

/// How the Glance view lays out a session's rows (spec §2 "Timeline"): reads, searches and fetches in a row collapse
/// into one quiet line, a subagent's rows nest under its Task, long output folds.
public enum TimelineBlock: Equatable, Sendable, Identifiable {
  case row(TimelineRow)
  case group(id: String, label: String, rows: [TimelineRow])
  case task(TimelineRow, children: [TimelineBlock])

  public var id: String {
    switch self {
    case .row(let row), .task(let row, _): row.id
    case .group(let id, _, _): id
    }
  }
}

public enum TimelineLayout {
  public static func blocks(_ rows: [TimelineRow]) -> [TimelineBlock] {
    var children: [String: [TimelineRow]] = [:]
    for row in rows { if let parent = row.parent { children[parent, default: []].append(row) } }
    return group(rows.filter { $0.parent == nil }, children: children)
  }

  private static func group(_ rows: [TimelineRow], children: [String: [TimelineRow]]) -> [TimelineBlock] {
    var out: [TimelineBlock] = [], run: [TimelineRow] = []
    func flush() {
      if let first = run.first { out.append(.group(id: "g-" + first.id, label: label(run), rows: run)) }
      run = []
    }
    for row in rows {
      if isQuiet(row) { run.append(row); continue }
      flush()
      if case .tool(_, .task, _, _) = row.kind {
        out.append(.task(row, children: group(children[row.id] ?? [], children: children)))
      } else {
        out.append(.row(row))
      }
    }
    flush()
    return out
  }

  /// A clip or explainer placed in the timeline at the time it happened.
  public struct MediaPlacement: Equatable, Sendable {
    public let capture: ProofCapture
    /// The id of the top-level row it follows; nil when it came before every row.
    public let after: String?
  }

  /// Where the session's clips and explainers go among its rows (screenshots show with their own tool call, other
  /// files not at all). Each follows the last row that is not inside a subagent, has a time, and is at or before the
  /// capture's `at`; before every row it comes first. In the order they happened.
  public static func mediaRows(captures: [ProofCapture], rows: [TimelineRow]) -> [MediaPlacement] {
    let anchors = rows.compactMap { row -> (id: String, time: Date)? in
      guard row.parent == nil, let time = row.time else { return nil }
      return (row.id, time)
    }
    return captures.enumerated()
      .filter { $0.element.kind == .clip || $0.element.kind == .explainer }
      .sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }
      .map { _, capture in
        MediaPlacement(capture: capture, after: anchors.last { $0.time <= capture.at }?.id)
      }
  }

  public static func isQuiet(_ row: TimelineRow) -> Bool {
    guard case .tool(_, let kind, let result, let denied) = row.kind, !denied, result?.isError != true else { return false }
    switch kind {
    case .read, .search, .web: return true
    default: return false
    }
  }

  public static func label(_ rows: [TimelineRow]) -> String {
    var reads: [String] = [], searches: [String] = [], webs = 0
    for row in rows {
      guard case .tool(_, let kind, _, _) = row.kind else { continue }
      switch kind {
      case .read(let path): reads.append(path)
      case .search(let pattern, _): searches.append(pattern)
      case .web: webs += 1
      default: break
      }
    }
    var parts: [String] = []
    if reads.count == 1 { parts.append("read \(reads[0])") } else if reads.count > 1 { parts.append("read \(reads.count) files") }
    if searches.count == 1 { parts.append("searched '\(searches[0])'") } else if searches.count > 1 { parts.append("searched \(searches.count) patterns") }
    if webs == 1 { parts.append("fetched 1 page") } else if webs > 1 { parts.append("fetched \(webs) pages") }
    let text = parts.joined(separator: ", ")
    return text.prefix(1).uppercased() + text.dropFirst()
  }

  public static func fold(_ output: String, limit: Int = 8) -> (shown: String, hidden: Int) {
    let lines = output.components(separatedBy: "\n")
    guard lines.count > limit else { return (output, 0) }
    return (lines.prefix(limit).joined(separator: "\n"), lines.count - limit)
  }

  /// A failed command's output folded to what explains the failure: every line carrying ✗, Error or FAIL plus the last
  /// `tail` lines, in order and without repeats. `hidden` counts the lines left out.
  public static func foldFailure(_ output: String, tail: Int = 4) -> (shown: String, hidden: Int) {
    let lines = output.components(separatedBy: "\n")
    let keep = lines.indices.filter { i in
      i >= lines.count - tail || ["✗", "Error", "FAIL"].contains(where: { lines[i].contains($0) })
    }
    return (keep.map { lines[$0] }.joined(separator: "\n"), lines.count - keep.count)
  }

  /// The button that unfolds hidden output: "Show 1 more line" / "Show 9 more lines", and for a failed command
  /// "Show all 40 lines (36 more)". Nil when nothing is hidden.
  public static func expandLabel(total: Int, hidden: Int, failed: Bool) -> String? {
    guard hidden > 0 else { return nil }
    if failed { return "Show all \(total) \(total == 1 ? "line" : "lines") (\(hidden) more)" }
    return "Show \(hidden) more \(hidden == 1 ? "line" : "lines")"
  }

  public static func counts(_ diff: [DiffLine]) -> (added: Int, removed: Int) {
    (diff.filter { $0.mark == .added }.count, diff.filter { $0.mark == .removed }.count)
  }
}
