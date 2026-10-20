import Foundation

/// One automation as search sees it: its manifest and README.
public struct AutomationSearchEntry: Equatable, Sendable {
  public var manifest: AutomationManifest
  public var readme: String

  public init(manifest: AutomationManifest, readme: String = "") {
    self.manifest = manifest
    self.readme = readme
  }
}

public struct AutomationSearchHit: Equatable, Sendable {
  public var id: String
  public var score: Int

  public init(id: String, score: Int) {
    self.id = id
    self.score = score
  }
}

/// The library's ranked search: the side bar's field and `automations_search` (spec "Claude: skill + Glance MCP").
/// Plain token scoring, the same on every call: each query word scores in every field it appears in, weighted
/// name (and id) 10 > tags 6 > description 3 > inputs 2 > README 1; a whole-word match counts double a prefix match.
/// Case and accents don't matter ("resume" finds "Résumé").
public enum AutomationSearch {
  static let weights = (name: 10, tags: 6, description: 3, inputs: 2, readme: 1)

  /// Best first; ties by name, then id. An empty query lists everything by name. Entries that match nothing are left
  /// out.
  public static func rank(_ query: String, in entries: [AutomationSearchEntry],
                          limit: Int = 20) -> [AutomationSearchHit] {
    let words = Array(Set(tokens(query)))
    let scored = entries.map { entry in (entry, words.reduce(0) { $0 + score($1, in: entry) }) }
      .filter { words.isEmpty || $0.1 > 0 }
      .sorted { left, right in
        if left.1 != right.1 { return left.1 > right.1 }
        let leftName = left.0.manifest.name.lowercased(), rightName = right.0.manifest.name.lowercased()
        if leftName != rightName { return leftName < rightName }
        return left.0.manifest.id < right.0.manifest.id
      }
    return scored.prefix(max(limit, 0)).map { AutomationSearchHit(id: $0.0.manifest.id, score: $0.1) }
  }

  static func score(_ word: String, in entry: AutomationSearchEntry) -> Int {
    let manifest = entry.manifest
    let fields: [(Int, String)] = [
      (weights.name, manifest.name + " " + manifest.id),
      (weights.tags, manifest.tags.joined(separator: " ")),
      (weights.description, manifest.description),
      (weights.inputs, manifest.inputs.map { $0.name + " " + ($0.description ?? "") }.joined(separator: " ")),
      (weights.readme, entry.readme),
    ]
    return fields.reduce(0) { total, field in
      let fieldTokens = tokens(field.1)
      if fieldTokens.contains(word) { return total + field.0 * 2 }
      if word.count >= 2, fieldTokens.contains(where: { $0.hasPrefix(word) }) { return total + field.0 }
      return total
    }
  }

  /// Lowercased, accent-free words: letters and digits in any script; everything else separates.
  /// "fix_red-CI" → ["fix", "red", "ci"].
  public static func tokens(_ text: String) -> [String] {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
  }
}
