import Foundation

/// How the Usage page writes tokens, dollars, changes and periods ("12.3K", "$4.56", "▲ 18%", "5–11 Oct").
public enum UsageFormat {
  public static func tokens(_ count: Int) -> String {
    guard count >= 1000 else { return "\(count)" }
    let suffixes = ["K", "M", "B", "T"]
    var value = Double(count) / 1000
    var index = 0
    while value >= 999.95, index < suffixes.count - 1 {
      value /= 1000
      index += 1
    }
    return trimmed(value, places: value < 10 ? 2 : value < 100 ? 1 : 0) + suffixes[index]
  }

  public static func cost(_ dollars: Double?) -> String {
    guard let dollars else { return "—" }
    if dollars == 0 { return "$0" }
    if dollars < 0.01 { return "<$0.01" }
    if dollars < 1000 { return String(format: "$%.2f", dollars) }
    return "$" + grouped(Int(dollars.rounded()))
  }

  public static func change(_ fraction: Double?) -> String? {
    guard let fraction else { return nil }
    let percent = Int((abs(fraction) * 100).rounded())
    if percent == 0 { return "0%" }
    return (fraction > 0 ? "▲ " : "▼ ") + "\(percent)%"
  }

  public static func percent(_ fraction: Double) -> String {
    if fraction > 0 && fraction < 0.005 { return "<1%" }
    return "\(Int((fraction * 100).rounded()))%"
  }

  /// "Thu 8 Oct", "5–11 Oct" (or "28 Sep – 4 Oct"), "October 2026".
  public static func title(_ period: UsagePeriod, calendar: Calendar, locale: Locale = .current) -> String {
    switch period.kind {
    case .day:
      return formatter("EEEdMMM", calendar, locale).string(from: period.start)
    case .month:
      return formatter("MMMMy", calendar, locale).string(from: period.start)
    case .week:
      let last = calendar.date(byAdding: .day, value: -1, to: period.end(calendar)) ?? period.start
      let month = formatter("MMM", calendar, locale)
      let first = calendar.component(.day, from: period.start)
      let lastDay = calendar.component(.day, from: last)
      if calendar.isDate(period.start, equalTo: last, toGranularity: .month) {
        return "\(first)–\(lastDay) \(month.string(from: last))"
      }
      return "\(first) \(month.string(from: period.start)) – \(lastDay) \(month.string(from: last))"
    }
  }

  /// A chart bar's label: "14:00" for an hour, "Thu 8 Oct" for a day.
  public static func bucket(_ start: Date, hourly: Bool, calendar: Calendar, locale: Locale = .current) -> String {
    formatter(hourly ? "jmm" : "EEEdMMM", calendar, locale).string(from: start)
  }

  /// "8 Oct 2026", for "Tracked since".
  public static func day(_ date: Date, calendar: Calendar, locale: Locale = .current) -> String {
    formatter("dMMMy", calendar, locale).string(from: date)
  }

  private static func formatter(_ template: String, _ calendar: Calendar, _ locale: Locale) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.setLocalizedDateFormatFromTemplate(template)
    return formatter
  }

  private static func trimmed(_ value: Double, places: Int) -> String {
    var text = String(format: "%.\(places)f", value)
    if text.contains(".") {
      while text.hasSuffix("0") { text.removeLast() }
      if text.hasSuffix(".") { text.removeLast() }
    }
    return text
  }

  private static func grouped(_ value: Int) -> String {
    let digits = Array(String(value))
    var out = ""
    for (index, digit) in digits.enumerated() {
      if index > 0 && (digits.count - index) % 3 == 0 { out.append(",") }
      out.append(digit)
    }
    return out
  }
}
