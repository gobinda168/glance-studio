import Foundation

/// A day, a week (from the calendar's first weekday) or a month, in the user's calendar (spec "Queries").
public struct UsagePeriod: Hashable, Sendable {
  public enum Kind: String, CaseIterable, Sendable {
    case day, week, month

    public var title: String {
      switch self {
      case .day: "Day"
      case .week: "Week"
      case .month: "Month"
      }
    }

    var component: Calendar.Component {
      switch self {
      case .day: .day
      case .week: .weekOfYear
      case .month: .month
      }
    }
  }

  public let kind: Kind
  public let start: Date

  public init(_ kind: Kind, containing date: Date, calendar: Calendar) {
    self.kind = kind
    start = calendar.dateInterval(of: kind.component, for: date)?.start ?? calendar.startOfDay(for: date)
  }

  public func end(_ calendar: Calendar) -> Date {
    calendar.date(byAdding: kind.component, value: 1, to: start) ?? start.addingTimeInterval(86_400)
  }

  public func contains(_ date: Date, calendar: Calendar) -> Bool {
    date >= start && date < end(calendar)
  }

  public func previous(_ calendar: Calendar) -> UsagePeriod {
    UsagePeriod(kind, containing: calendar.date(byAdding: kind.component, value: -1, to: start) ?? start,
                calendar: calendar)
  }

  public func next(_ calendar: Calendar) -> UsagePeriod {
    UsagePeriod(kind, containing: end(calendar), calendar: calendar)
  }

  /// The chart's bars: hours for a day (23 or 25 on a DST change), days for a week or month.
  public func bucketStarts(_ calendar: Calendar) -> [Date] {
    let step: Calendar.Component = kind == .day ? .hour : .day
    let end = end(calendar)
    var starts: [Date] = []
    var current = start
    while current < end {
      starts.append(current)
      guard let next = calendar.date(byAdding: step, value: 1, to: current), next > current else { break }
      current = next
    }
    return starts
  }
}

/// What the Usage page shows for a period (spec "Queries"): totals, chart buckets, tables by model and by project, and
/// the change in cost from the period before. Shares follow cost, or tokens when nothing in the period has a price.
public struct UsageReport: Sendable {
  public struct Bucket: Identifiable, Sendable {
    public let start: Date
    public let tokens: UsageTokens
    public let cost: Double
    public var id: Date { start }
  }

  public struct Share: Identifiable, Sendable {
    /// The normalized model id, or the project path ("" for background runs).
    public let key: String
    public let name: String
    public let tokens: UsageTokens
    /// Nil when none of its requests has a price.
    public let cost: Double?
    public let share: Double
    /// The part of its tokens that subagents used.
    public let subagentShare: Double
    public var id: String { key }
  }

  public static let backgroundName = "Glance (background)"

  public let period: UsagePeriod
  public let totals: UsageTokens
  public let cost: Double
  /// Tokens from models without a price: counted in `totals`, not in `cost`.
  public let unpricedTokens: Int
  public let requests: Int
  public let buckets: [Bucket]
  public let models: [Share]
  public let projects: [Share]
  /// The cost's change from the period before, as a fraction; nil when that period cost nothing or wasn't tracked from
  /// its start (a partly tracked period would make any change look huge).
  public let change: Double?
  public let trackedSince: Date?

  /// `records` may hold the period before too (for `change`); anything else is ignored.
  public static func make(period: UsagePeriod, records: [UsageRecord], calendar: Calendar, trackedSince: Date?,
                          home: String = NSHomeDirectory()) -> UsageReport {
    let previous = period.previous(calendar)
    let inPeriod = records.filter { period.contains($0.time, calendar: calendar) }
    let previousCost = records.filter { previous.contains($0.time, calendar: calendar) }
      .reduce(0) { $0 + (UsagePricing.cost($1) ?? 0) }

    var totals = UsageTokens()
    var cost = 0.0
    var unpriced = 0
    let starts = period.bucketStarts(calendar)
    var bucketTokens = Array(repeating: UsageTokens(), count: starts.count)
    var bucketCost = Array(repeating: 0.0, count: starts.count)
    var models: [String: Tally] = [:]
    var projects: [String: Tally] = [:]
    for record in inPeriod {
      let tokens = record.tokens
      let price = UsagePricing.cost(record)
      totals = totals + tokens
      cost += price ?? 0
      if price == nil { unpriced += tokens.total }
      if let index = starts.lastIndex(where: { $0 <= record.time }) {
        bucketTokens[index] = bucketTokens[index] + tokens
        bucketCost[index] += price ?? 0
      }
      let model = UsagePricing.normalize(record.model)
      models[model, default: Tally(name: UsagePricing.displayName(record.model))].add(record, tokens, price)
      let name = record.project.isEmpty ? backgroundName : FolderLabel.name(forPath: record.project, home: home)
      projects[record.project, default: Tally(name: name)].add(record, tokens, price)
    }
    let buckets = starts.indices.map { Bucket(start: starts[$0], tokens: bucketTokens[$0], cost: bucketCost[$0]) }
    return UsageReport(
      period: period, totals: totals, cost: cost, unpricedTokens: unpriced, requests: inPeriod.count,
      buckets: buckets, models: shares(models, cost: cost, tokens: totals.total),
      projects: shares(projects, cost: cost, tokens: totals.total),
      change: previousCost > 0 && (trackedSince.map { $0 <= previous.start } ?? false)
        ? (cost - previousCost) / previousCost : nil,
      trackedSince: trackedSince)
  }

  private struct Tally {
    var name: String
    var tokens = UsageTokens()
    var cost: Double?
    var subagentTokens = 0

    init(name: String) { self.name = name }

    mutating func add(_ record: UsageRecord, _ tokens: UsageTokens, _ price: Double?) {
      self.tokens = self.tokens + tokens
      if let price { cost = (cost ?? 0) + price }
      if record.subagent { subagentTokens += tokens.total }
    }
  }

  private static func shares(_ tallies: [String: Tally], cost: Double, tokens: Int) -> [Share] {
    tallies.map { key, tally in
      let share = cost > 0 ? (tally.cost ?? 0) / cost : tokens > 0 ? Double(tally.tokens.total) / Double(tokens) : 0
      let subagents = tally.tokens.total > 0 ? Double(tally.subagentTokens) / Double(tally.tokens.total) : 0
      return Share(key: key, name: tally.name, tokens: tally.tokens, cost: tally.cost, share: share,
                   subagentShare: subagents)
    }
    .sorted { $0.share != $1.share ? $0.share > $1.share : $0.name < $1.name }
  }
}
