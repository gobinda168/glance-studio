import Foundation

/// The Notifications page's Catch me up (spec 2026-10-09-notifications-design.md, "Catch me up"): one Claude run over
/// the unread rows that answers a short brief, each line naming the rows it's about by their thread keys. Pure: the
/// prompt, the reply's parser, and when a brief has gone stale.
public enum CatchUp {
  /// At most this many unread rows go into the prompt, newest first.
  public static let maxRows = 60
  /// A brief is stale once this many unread rows it didn't cover are on the page.
  public static let staleAfter = 3

  public struct Line: Equatable, Sendable {
    public let text: String
    /// The thread keys (`NoticeBook.Row.id`) of the rows the line is about.
    public let ids: [String]

    public init(text: String, ids: [String]) {
      self.text = text
      self.ids = ids
    }
  }

  public struct Brief: Equatable, Sendable {
    public let summary: String
    public let lines: [Line]

    public init(summary: String, lines: [Line]) {
      self.summary = summary
      self.lines = lines
    }
  }

  /// The run's prompt: the unread rows, newest first, at most 60, each with its `[key]` for the answer's ids.
  public static func prompt(rows: [NoticeBook.Row], now: Date) -> String {
    let unread = rows.enumerated().filter { $0.element.unread }
      .sorted { $0.element.newest.date != $1.element.newest.date
        ? $0.element.newest.date > $1.element.newest.date : $0.offset < $1.offset }
      .prefix(maxRows).map(\.element)
    var lines = [
      "These are the user's unread notifications in Glance, newest first. Write a short brief: what needs the user "
        + "first, then what can wait. 3 to 7 lines, each under 20 words, naming people and places. Answer with only "
        + "JSON:",
      #"{"summary":"<one sentence>","lines":[{"text":"…","ids":["<key>",…]}]} where ids are the [keys] of the rows a line is about."#,
      "Rows:",
    ]
    lines += unread.map { line($0, now: now) }
    return lines.joined(separator: "\n")
  }

  /// `[key] Slack · Direct messages · Riya · DM · 4m ago — the preview (+2 more in thread)`
  static func line(_ row: NoticeBook.Row, now: Date) -> String {
    let notice = row.newest
    let place = notice.place.flatMap { $0.isEmpty ? nil : $0 }
    var text = "[\(notice.threadKey)] "
      + [notice.source.title, notice.kind.label, notice.title, place, age(notice.date, now: now)]
      .compactMap { $0 }.joined(separator: " · ")
    if !notice.preview.isEmpty { text += " — " + notice.preview }
    if row.folded > 0 { text += " (+\(row.folded) more in thread)" }
    return text
  }

  /// "just now", "4m ago", "2h ago", "3d ago".
  static func age(_ date: Date, now: Date) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    if seconds < 60 { return "just now" }
    if seconds < 3_600 { return "\(Int(seconds / 60))m ago" }
    if seconds < 86_400 { return "\(Int(seconds / 3_600))h ago" }
    return "\(Int(seconds / 86_400))d ago"
  }

  /// The brief in Claude's answer (fenced or in prose); nil without at least one line with words.
  public static func brief(from text: String) -> Brief? {
    guard let object = ClaudeJSON.object(in: text), let raw = object["lines"] as? [Any] else { return nil }
    let lines = raw.compactMap { item -> Line? in
      guard let item = item as? [String: Any], let text = item["text"] as? String else { return nil }
      let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !words.isEmpty else { return nil }
      let ids = (item["ids"] as? [Any] ?? []).compactMap { $0 as? String }
      return Line(text: words, ids: ids)
    }
    guard !lines.isEmpty else { return nil }
    let summary = (object["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return Brief(summary: summary, lines: lines)
  }

  /// 3 or more unread rows that weren't unread when the brief was asked for.
  public static func isStale(briefRowKeys: Set<String>, current: [NoticeBook.Row]) -> Bool {
    current.filter { $0.unread && !briefRowKeys.contains($0.id) }.count >= staleAfter
  }
}
