import Foundation

extension FileService {
  /// Finds `query` in the project's files (the ones ⌘P lists), in path order, up to `limit` matches. Files that can't be
  /// read as text (binary, over 2 MB, not UTF-8) are skipped.
  public func search(
    query: String, options: SearchOptions, limit: Int = 1000, isCancelled: @Sendable () -> Bool = { false }
  ) throws -> SearchResult {
    let regex = try ProjectSearch.makeRegex(query: query, options: options)
    var matches: [SearchMatch] = []
    var paths = Set<String>()
    var truncated = false
    for path in listFiles() {
      if isCancelled() { throw SearchError.cancelled }
      guard let document = try? read(path) else { continue }
      let found = ProjectSearch.matches(in: document.text, path: path, regex: regex, limit: limit - matches.count)
      guard !found.isEmpty else { continue }
      matches += found
      paths.insert(path)
      if matches.count >= limit { truncated = true; break }
    }
    return SearchResult(matches: matches, truncated: truncated, fileCount: paths.count)
  }

  /// Replaces every match of `query` with `replacement` on disk, in `paths` (default: every file with a match). Files
  /// in `skipping` are left alone and reported; a file that changed since it was read, or can't be written, is reported
  /// in `failed` and the others still go ahead. A literal replacement is taken literally; a regex replacement may use
  /// `$1`-style groups. Refuses patterns that can match empty text.
  public func replace(
    query: String, options: SearchOptions, replacement: String, paths: [String]? = nil, skipping: Set<String> = [],
    isCancelled: @Sendable () -> Bool = { false }
  ) throws -> ReplaceResult {
    let regex = try ProjectSearch.makeRegex(query: query, options: options)
    guard regex.firstMatch(in: "", range: NSRange(location: 0, length: 0)) == nil else { throw SearchError.matchesEmpty }
    let template = options.regex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
    var result = ReplaceResult(replacements: 0, files: 0, skipped: [], failed: [])
    for path in paths ?? listFiles() {
      if isCancelled() { throw SearchError.cancelled }
      guard let document = try? read(path) else { continue }
      let whole = NSRange(location: 0, length: (document.text as NSString).length)
      let count = regex.numberOfMatches(in: document.text, range: whole)
      guard count > 0 else { continue }
      if skipping.contains(path) { result.skipped.append(path); continue }
      let updated = regex.stringByReplacingMatches(in: document.text, range: whole, withTemplate: template)
      do {
        try save(path, text: updated, expectedModified: document.modified, bom: document.bom)
        result.replacements += count
        result.files += 1
      } catch let failure as Failure {
        result.failed.append(ReplaceFailure(path: path, message: failure.message))
      } catch {
        result.failed.append(ReplaceFailure(path: path, message: error.localizedDescription))
      }
    }
    return result
  }
}
