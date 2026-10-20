import Foundation

/// What a request would cost at Anthropic's API rates (spec "Pricing"): USD per million tokens by model, from the
/// claude-api skill's table cached 2026-09-25. Cache writes cost 1.25× input for 5 minutes and 2× for an hour; fast
/// mode doubles everything. A model not in the table has no cost; its tokens still count.
public enum UsagePricing {
  public struct Price: Equatable, Sendable {
    public let input: Double
    public let output: Double
    public let cacheRead: Double
  }

  /// When the table was last checked, for the page's footer.
  public static let asOf = "25 Sep 2026"

  static let table: [String: Price] = [
    "claude-fable-5-1": Price(input: 10, output: 50, cacheRead: 0.25),
    "claude-mythos-5-1": Price(input: 10, output: 50, cacheRead: 0.25),
    "claude-fable-5": Price(input: 10, output: 50, cacheRead: 1),
    "claude-mythos-5": Price(input: 10, output: 50, cacheRead: 1),
    "claude-opus-5-5": Price(input: 4, output: 20, cacheRead: 0.2),
    "claude-opus-5": Price(input: 5, output: 25, cacheRead: 0.5),
    "claude-opus-4-8": Price(input: 5, output: 25, cacheRead: 0.5),
    "claude-opus-4-7": Price(input: 5, output: 25, cacheRead: 0.5),
    "claude-opus-4-6": Price(input: 5, output: 25, cacheRead: 0.5),
    "claude-sonnet-5-5": Price(input: 2, output: 10, cacheRead: 0.2),
    "claude-sonnet-5": Price(input: 2, output: 10, cacheRead: 0.2),
    "claude-sonnet-4-6": Price(input: 3, output: 15, cacheRead: 0.3),
    "claude-haiku-4-5": Price(input: 1, output: 5, cacheRead: 0.1),
  ]

  /// The bare model id: lowercased, without a platform prefix (`us.anthropic.`), a `[1m]` tag, a Vertex `@date` or a
  /// trailing `-YYYYMMDD`.
  public static func normalize(_ model: String) -> String {
    var id = model.lowercased()
    if let claude = id.range(of: "claude-") { id = String(id[claude.lowerBound...]) }
    if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }
    if let at = id.firstIndex(of: "@") { id = String(id[..<at]) }
    if let dash = id.lastIndex(of: "-") {
      let tail = id[id.index(after: dash)...]
      if tail.count == 8, tail.allSatisfy(\.isNumber) { id = String(id[..<dash]) }
    }
    return id
  }

  /// The table's price for `model`: its exact id, else the longest id it extends (`claude-opus-5-5-x` → Opus 5.5).
  public static func price(for model: String) -> Price? {
    let id = normalize(model)
    if let exact = table[id] { return exact }
    return table.keys.filter { id.hasPrefix($0 + "-") }.max { $0.count < $1.count }.flatMap { table[$0] }
  }

  /// The request's cost in USD, or nil when its model has no price.
  public static func cost(_ record: UsageRecord) -> Double? {
    guard let price = price(for: record.model) else { return nil }
    let dollars = Double(record.input) * price.input
      + Double(record.output) * price.output
      + Double(record.cacheWrite5m) * price.input * 1.25
      + Double(record.cacheWrite1h) * price.input * 2
      + Double(record.cacheRead) * price.cacheRead
    return dollars / 1_000_000 * (record.fast ? 2 : 1)
  }

  /// "Opus 5.5" for `claude-opus-5-5`; any other id as it is.
  public static func displayName(_ model: String) -> String {
    let id = normalize(model)
    guard id.hasPrefix("claude-") else { return model }
    let parts = id.dropFirst("claude-".count).split(separator: "-")
    guard let family = parts.first else { return model }
    let version = parts.dropFirst().joined(separator: ".")
    return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version)"
  }
}
