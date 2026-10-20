import Foundation

/// Claude Code's plan limits (the rolling 5-hour window and the weekly one), as its status line reports them.
public struct PlanUsage: Equatable, Sendable {
  public struct Window: Equatable, Sendable {
    public enum Severity: String, Sendable { case normal, warn, critical }

    /// 0...100.
    public let percent: Double
    public let resetsAt: Date

    public init(percent: Double, resetsAt: Date) {
      self.percent = min(max(percent, 0), 100)
      self.resetsAt = resetsAt
    }

    /// The whole number the panel shows.
    public var shownPercent: Int { Int(percent.rounded()) }

    public var severity: Severity { Self.severity(shownPercent: shownPercent) }

    /// High from 70%, near the limit from 90%.
    public static func severity(shownPercent: Int) -> Severity {
      shownPercent >= 90 ? .critical : shownPercent >= 70 ? .warn : .normal
    }

    /// "resets in 2h 10m", "resets in 3d 4h", "resets in under a minute".
    public func resetText(now: Date) -> String {
      resetsAt.timeIntervalSince(now) < 60 ? "resets in under a minute" : "resets in " + shortResetText(now: now)
    }

    /// The countdown alone: "2h 10m", "3d 4h", "<1m".
    public func shortResetText(now: Date) -> String {
      let seconds = Int(resetsAt.timeIntervalSince(now))
      let minutes = seconds / 60
      let hours = minutes / 60
      let days = hours / 24
      if seconds < 60 { return "<1m" }
      if hours < 1 { return "\(minutes)m" }
      if days < 1 { return Self.pair(hours, "h", minutes % 60, "m") }
      return Self.pair(days, "d", hours % 24, "h")
    }

    private static func pair(_ big: Int, _ bigUnit: String, _ small: Int, _ smallUnit: String) -> String {
      small == 0 ? "\(big)\(bigUnit)" : "\(big)\(bigUnit) \(small)\(smallUnit)"
    }
  }

  /// A reset further ahead than this isn't a rate-limit window: a week, with a day to spare.
  private static let maxHorizon: TimeInterval = 8 * 86400

  public let fiveHour: Window?
  public let sevenDay: Window?

  public init(fiveHour: Window?, sevenDay: Window?) {
    self.fiveHour = fiveHour
    self.sevenDay = sevenDay
  }

  /// The `rate_limits` of a status-line payload. A window already past its reset is dropped, as Claude Code does.
  /// Nil when there's nothing left to show (an API-key user, a half-written file, both windows over).
  public static func parse(_ data: Data, now: Date) -> PlanUsage? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let limits = root["rate_limits"] as? [String: Any] else { return nil }
    func window(_ key: String) -> Window? {
      guard let object = limits[key] as? [String: Any],
        let percent = (object["used_percentage"] as? NSNumber)?.doubleValue,
        let reset = (object["resets_at"] as? NSNumber)?.doubleValue else { return nil }
      let resetsAt = Date(timeIntervalSince1970: reset)
      // Past, or implausibly far ahead (the longest window is a week): a corrupt file must not reach the text code.
      guard resetsAt > now, resetsAt.timeIntervalSince(now) <= maxHorizon else { return nil }
      return Window(percent: percent, resetsAt: resetsAt)
    }
    let usage = PlanUsage(fiveHour: window("five_hour"), sevenDay: window("seven_day"))
    return usage.fiveHour == nil && usage.sevenDay == nil ? nil : usage
  }

  /// "updated 4m ago": how old the numbers are.
  public static func ageText(updated: Date, now: Date) -> String {
    let seconds = Int(now.timeIntervalSince(updated))
    if seconds < 60 { return "updated just now" }
    if seconds < 3600 { return "updated \(seconds / 60)m ago" }
    if seconds < 86400 { return "updated \(seconds / 3600)h ago" }
    return "updated \(seconds / 86400)d ago"
  }

  /// The top bar's tooltip: one line per present window, then the age.
  public func hoverText(now: Date, updated: Date) -> String {
    var lines: [String] = []
    if let fiveHour { lines.append("5-hour limit: \(fiveHour.shownPercent)% used, \(fiveHour.resetText(now: now))") }
    if let sevenDay { lines.append("Weekly limit: \(sevenDay.shownPercent)% used, \(sevenDay.resetText(now: now))") }
    lines.append(Self.ageText(updated: updated, now: now))
    return lines.joined(separator: "\n")
  }

  /// Reads the status-line script's `usage.json`: the usage in it and when the file was last written.
  public static func load(from url: URL, now: Date) -> (usage: PlanUsage, updated: Date)? {
    guard let data = try? Data(contentsOf: url), let usage = parse(data, now: now),
      let updated = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    else { return nil }
    return (usage, updated)
  }
}
