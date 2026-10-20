import Foundation

/// A candidate that matches what was typed, with the characters of its name that matched.
public struct CompletionMatch: Equatable, Sendable, Identifiable {
  public let candidate: CompletionCandidate
  /// Character ranges of `candidate.name` the query matched.
  public let highlight: [Range<Int>]
  public var id: Int { candidate.index }
}

/// One of zsh's groups in the menu.
public struct CompletionSection: Equatable, Sendable, Identifiable {
  public let title: String
  public let matches: [CompletionMatch]
  public var id: String { title }
}

/// Narrowing the Tab menu as the user keeps typing (spec "S1: the Tab menu"): prefix matches first, then fuzzy ones.
public enum CompletionFilter {
  /// What the user has typed for a candidate: the line from `start` to `cursor` (zsh's character positions), less the
  /// candidate's hidden prefix when the text begins with it. Nil when the cursor is before the start or past the line.
  public static func query(line: String, cursor: Int, start: Int, hidden: String) -> String? {
    let scalars = Array(line.unicodeScalars)
    guard start >= 0, cursor >= start, cursor <= scalars.count else { return nil }
    var view = String.UnicodeScalarView()
    view.append(contentsOf: scalars[start..<cursor])
    let typed = String(view)
    if !hidden.isEmpty, typed.hasPrefix(hidden) { return String(typed.dropFirst(hidden.count)) }
    return typed
  }

  /// The candidates `query` matches (nil: none), grouped in the order zsh gave the groups. Within a group prefix
  /// matches come before fuzzy ones; ordered groups keep zsh's order, the others sort by name.
  public static func sections(_ candidates: [CompletionCandidate],
                              query: (CompletionCandidate) -> String?,
                              boost: (CompletionCandidate) -> Double = { _ in 0 }) -> [CompletionSection] {
    var order: [String] = []
    var groups: [String: [(match: CompletionMatch, prefix: Bool, position: Int, boost: Double)]] = [:]
    for (position, candidate) in candidates.enumerated() {
      guard let typed = query(candidate), let found = match(typed, in: candidate.name) else { continue }
      if groups[candidate.group] == nil { order.append(candidate.group) }
      groups[candidate.group, default: []].append(
        (CompletionMatch(candidate: candidate, highlight: found.ranges), found.prefix, position, boost(candidate)))
    }
    return order.map { title in
      let entries = groups[title] ?? []
      let sorted = entries.sorted { a, b in
        if a.prefix != b.prefix { return a.prefix }
        // What was picked here before comes first (spec "S3").
        if a.boost != b.boost { return a.boost > b.boost }
        if a.match.candidate.isOrdered || b.match.candidate.isOrdered { return a.position < b.position }
        let order = a.match.candidate.name.localizedStandardCompare(b.match.candidate.name)
        return order == .orderedSame ? a.position < b.position : order == .orderedAscending
      }
      return CompletionSection(title: title, matches: sorted.map(\.match))
    }
  }

  /// Where `query` matches `name`, ignoring case: as a prefix, else as a subsequence (fuzzy). Nil when it doesn't.
  static func match(_ query: String, in name: String) -> (prefix: Bool, ranges: [Range<Int>])? {
    let needle = Array(query.lowercased())
    guard !needle.isEmpty else { return (true, []) }
    let hay = Array(name.lowercased())
    if hay.starts(with: needle) { return (true, [0..<needle.count]) }
    var ranges: [Range<Int>] = []
    var n = 0
    for (i, character) in hay.enumerated() where n < needle.count && character == needle[n] {
      if let last = ranges.last, last.upperBound == i {
        ranges[ranges.count - 1] = last.lowerBound..<(i + 1)
      } else {
        ranges.append(i..<(i + 1))
      }
      n += 1
    }
    return n == needle.count ? (false, ranges) : nil
  }
}
