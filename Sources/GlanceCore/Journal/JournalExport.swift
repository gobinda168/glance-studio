import Foundation

/// Export… in Settings → Journal (spec "The on/off switch and disclaimer"): everything as one JSON file, and the
/// recaps and entries as Markdown, a file per month. The JSON shape is where stage 3's sync starts.
public enum JournalExport {
  public struct File: Codable, Equatable, Sendable {
    public var schema: Int
    public var exportedAt: Date
    public var days: [JournalDayRecord]
    public var events: [JournalEvent]
    public var entries: [JournalEntry]

    public init(schema: Int, exportedAt: Date, days: [JournalDayRecord], events: [JournalEvent],
                entries: [JournalEntry]) {
      self.schema = schema
      self.exportedAt = exportedAt
      self.days = days
      self.events = events
      self.entries = entries
    }
  }

  public static func json(days: [JournalDayRecord], events: [JournalEvent], entries: [JournalEntry],
                          exportedAt: Date) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(File(schema: JournalStore.schema, exportedAt: exportedAt, days: days, events: events,
                                   entries: entries))
  }

  /// "YYYY-MM.md" → that month's days, oldest first, each with its headline, recap and entries. Days with neither a
  /// recap nor entries are left out.
  public static func markdown(days: [JournalDayRecord], entries: [JournalEntry], calendar: Calendar,
                              name: (String) -> String) -> [String: String] {
    let entriesByDay = Dictionary(grouping: entries, by: \.day)
    let written = days.filter { !$0.headline.isEmpty || !(entriesByDay[$0.day] ?? []).isEmpty }
    let byMonth = Dictionary(grouping: written) { String($0.day.key.prefix(7)) }
    var files: [String: String] = [:]
    for (month, monthDays) in byMonth {
      var lines = ["# \(JournalAnalytics.monthTitle(month, calendar: calendar))"]
      for record in monthDays.sorted(by: { $0.day < $1.day }) {
        let date = JournalDigest.longDate(record.day, calendar: calendar)
        lines += ["", "## " + (record.headline.isEmpty ? date : "\(date) · \(record.headline)")]
        if !record.recap.isEmpty { lines += ["", record.recap] }
        for entry in (entriesByDay[record.day] ?? []).sorted(by: { $0.position < $1.position }) {
          lines += ["", "### " + (entry.highlight ? "★ " : "") + entry.title]
          lines.append(([entry.kind.title] + (entry.project.map { [name($0)] } ?? [])
            + (entry.minutes > 0 ? [duration(minutes: entry.minutes)] : [])).joined(separator: " · "))
          if !entry.summary.isEmpty { lines += ["", entry.summary] }
          let story = [("Impact", entry.impact), ("Challenge", entry.challenge), ("Approach", entry.approach),
                       ("Outcome", entry.outcome), ("Lesson", entry.lesson),
                       ("Skills", entry.skills.joined(separator: ", "))].filter { !$0.1.isEmpty }
          if !story.isEmpty { lines += [""] + story.map { "- **\($0.0):** \($0.1)" } }
        }
      }
      files[month + ".md"] = lines.joined(separator: "\n") + "\n"
    }
    return files
  }

  /// "30 min", "1 h", "1 h 35 min".
  public static func duration(minutes: Int) -> String {
    let hours = minutes / 60
    let rest = minutes % 60
    if hours == 0 { return "\(rest) min" }
    return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
  }
}
