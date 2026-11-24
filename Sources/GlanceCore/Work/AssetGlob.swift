import Foundation

/// The folder patterns a project's setup names for Assets (`"assets": ["docs/screens/**"]`), matched against paths
/// relative to the worktree root.
///
/// `**` as a whole folder matches any number of folders (none included); `*` and `?` stay inside one name. A pattern
/// with no `/` names files wherever they are (`*.png` matches `docs/a.png`), as in a `.gitignore`. Case matters.
/// Absolute paths, `~`, and `..` in either the pattern or the path never match, so a pattern can't reach out of the tree.
public enum AssetGlob {
  public static func matches(_ pattern: String, path: String) -> Bool {
    guard var patterns = parts(pattern), let segments = parts(path), patterns.count <= 32, segments.count <= 64 else { return false }
    // Each `**` can try every split of the path below it, so only a few are allowed.
    guard patterns.filter({ $0 == "**" }).count <= 4 else { return false }
    if patterns.count == 1, patterns[0] != "**" { patterns.insert("**", at: 0) }
    return folders(patterns[...], segments[...])
  }

  /// Non-empty, not absolute, no `.` / `..` / `~`, no NUL, bounded: nil otherwise.
  private static func parts(_ text: String) -> [String]? {
    guard !text.isEmpty, text.count <= 512, !text.hasPrefix("/"), !text.hasPrefix("~"), !text.contains("\0"), !text.contains("\\") else { return nil }
    let parts = text.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
    return parts
  }

  private static func folders(_ pattern: ArraySlice<String>, _ path: ArraySlice<String>) -> Bool {
    guard let head = pattern.first else { return path.isEmpty }
    if head == "**" {
      let rest = pattern.dropFirst()
      // `**` last takes everything below; otherwise try every split.
      if rest.isEmpty { return !path.isEmpty }
      var tail = path
      while true {
        if folders(rest, tail) { return true }
        guard !tail.isEmpty else { return false }
        tail = tail.dropFirst()
      }
    }
    guard let name = path.first, nameMatches(head, name) else { return false }
    return folders(pattern.dropFirst(), path.dropFirst())
  }

  /// One folder or file name against one pattern segment (`*` any run, `?` one character), in linear time.
  private static func nameMatches(_ pattern: String, _ name: String) -> Bool {
    let p = Array(pattern), n = Array(name)
    var pi = 0, ni = 0, star = -1, mark = 0
    while ni < n.count {
      if pi < p.count, p[pi] == "?" || p[pi] == n[ni] && p[pi] != "*" { pi += 1; ni += 1 }
      else if pi < p.count, p[pi] == "*" { star = pi; mark = ni; pi += 1 }
      else if star >= 0 { pi = star + 1; mark += 1; ni = mark }
      else { return false }
    }
    while pi < p.count, p[pi] == "*" { pi += 1 }
    return pi == p.count
  }
}
