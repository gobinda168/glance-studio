import Foundation

/// The ⌘P file finder's ranking. A query matches a path when its letters appear in order (any case); filename
/// matches beat folder matches, and shallow, short paths win ties.
public enum QuickOpen {
  public static func rank(_ query: String, in paths: [String], limit: Int = 50) -> [String] {
    let query = query.lowercased()
    guard !query.isEmpty else {
      return Array(paths.sorted { (depth($0), $0) < (depth($1), $1) }.prefix(limit))
    }
    var scored: [(path: String, score: Int)] = []
    for path in paths {
      if let score = score(query, path) { scored.append((path, score)) }
    }
    scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path }
    return scored.prefix(limit).map(\.path)
  }

  private static func depth(_ path: String) -> Int { path.filter { $0 == "/" }.count }

  private static func isSubsequence(_ query: String, of text: String) -> Bool {
    var remaining = query[...]
    for character in text where character == remaining.first {
      remaining.removeFirst()
      if remaining.isEmpty { return true }
    }
    return remaining.isEmpty
  }

  private static func score(_ query: String, _ path: String) -> Int? {
    let lower = path.lowercased()
    let name = lower.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? lower
    var score: Int
    if !query.contains("/"), isSubsequence(query, of: name) {
      score = 2000
      if name.hasPrefix(query) { score += 300 }
      if name.contains(query) { score += 200 }
    } else if isSubsequence(query, of: lower) {
      score = 1000
      if lower.contains(query) { score += 200 }
    } else {
      return nil
    }
    return score - 10 * depth(path) - path.count
  }
}
