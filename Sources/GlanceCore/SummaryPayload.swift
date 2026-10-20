import Foundation

/// What `glance.summary(…)` gets (Web/summary.js): the Summary view's state, title, freshness line, and the summary as
/// pane blocks (spec 2026-10-11-humanize-summaries-design.md, "Settings and UI").
public enum SummaryPayload {
  public enum Kind: String { case none, working, ready, failed }

  public static func make(kind: Kind, record: SummaryRecord?, stale: Bool, message: String?, mode: SummaryMode,
                          now: Date) -> [String: Any] {
    var payload: [String: Any] = ["state": kind.rawValue, "stale": stale, "mode": mode.rawValue,
                                  "title": record?.title ?? "This session", "message": message ?? NSNull()]
    if let record, !record.summary.isEmpty {
      payload["meta"] = "up to turn \(record.coveredTurns) · \(ago(record.updatedAt, now: now))"
      payload["blocks"] = Blocks.split(record.summary).map {
        ["kind": $0.kind.rawValue, "markdown": $0.markdown, "lang": $0.lang ?? NSNull()] as [String: Any]
      }
    }
    if kind == .none { payload["hint"] = "Summarizing reads this session once with Haiku. Nothing runs until you ask." }
    return payload
  }

  static func ago(_ date: Date, now: Date) -> String {
    let minutes = Int(now.timeIntervalSince(date) / 60)
    if minutes < 1 { return "just now" }
    if minutes < 60 { return "\(minutes) min ago" }
    let hours = minutes / 60
    return hours < 24 ? "\(hours) h ago" : "\(hours / 24) d ago"
  }
}
