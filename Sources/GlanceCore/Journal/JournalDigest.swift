import Foundation

/// The text of a day Claude reads to write its recap (spec 2026-10-09-journal-design.md, "The digest"): grouped by
/// project, most active first, then meetings and notes, every event marked [eN] for Claude to cite. Already-redacted
/// event text only: never transcripts, diffs or terminal commands. At most `limit` characters: long prompt lists are
/// trimmed first, then file lists, then the oldest commits; past that the text is cut.
public struct JournalDigest: Equatable, Sendable {
  public static let limit = 30_000

  public let text: String
  /// "e1" → `JournalEvent.id`.
  public let refs: [String: String]
  /// A project's heading → the project (a folder, or "owner/name"), to map Claude's project names back.
  public let projects: [String: String]

  private struct Trim {
    var prompts = false
    var files = false
    var droppedCommits = 0
  }

  public static func make(day: JournalDay, calendar: Calendar, events: [JournalEvent],
                          name: (String) -> String = { FolderLabel.name(forPath: $0) }) -> JournalDigest {
    let commits = events.filter { $0.source == .git }.count
    let step = max(1, commits / 10)
    var trims = [Trim(), Trim(prompts: true), Trim(prompts: true, files: true)]
    trims += stride(from: step, to: commits, by: step).map { Trim(prompts: true, files: true, droppedCommits: $0) }
    if commits > 0 { trims.append(Trim(prompts: true, files: true, droppedCommits: commits)) }
    var digest = render(day: day, calendar: calendar, events: events, name: name, trim: trims[0])
    for trim in trims {
      digest = render(day: day, calendar: calendar, events: events, name: name, trim: trim)
      if digest.text.count <= limit { return digest }
    }
    let note = "\n[The rest of the day was cut: \(digest.text.count - (limit - 120)) characters.]"
    return JournalDigest(text: String(digest.text.prefix(limit - 120)) + note, refs: digest.refs,
                         projects: digest.projects)
  }

  private static func render(day: JournalDay, calendar: Calendar, events: [JournalEvent], name: (String) -> String,
                             trim: Trim) -> JournalDigest {
    var lines = [
      "Journal digest for \(longDate(day, calendar: calendar)) (time zone \(calendar.timeZone.identifier)). "
        + "Times are local.",
      "[eN] marks an event; cite them in event_refs.",
    ]
    var refs: [String: String] = [:]
    var projects: [String: String] = [:]
    func ref(_ event: JournalEvent) -> String {
      let key = "e\(refs.count + 1)"
      refs[key] = event.id
      return "[\(key)]"
    }
    let dropped = Set(events.filter { $0.source == .git }.sorted { $0.start < $1.start }.prefix(trim.droppedCommits)
      .map(\.id))
    let worked = events.filter { [.claude, .git, .pr, .review].contains($0.source) && $0.project != nil }
    let groups = Dictionary(grouping: worked) { $0.project ?? "" }
    func active(_ project: String) -> Int {
      (groups[project] ?? []).reduce(0) { $0 + ($1.detail.activeMinutes ?? 0) }
    }
    let ordered = groups.keys.sorted { active($0) != active($1) ? active($0) > active($1) : name($0) < name($1) }
    for project in ordered {
      var heading = name(project)
      if projects[heading] != nil { heading = project }
      projects[heading] = project
      let minutes = active(project)
      lines += ["", "## \(heading) — \(project)" + (minutes > 0 ? " — \(minutes) active min" : "")]
      for event in (groups[project] ?? []).sorted(by: { $0.start < $1.start }) where !dropped.contains(event.id) {
        lines += describe(event, ref: ref(event), calendar: calendar, trim: trim)
      }
    }
    if trim.droppedCommits > 0 { lines += ["", "[\(trim.droppedCommits) older commits left out.]"] }
    let meetings = events.filter { $0.source == .meeting }.sorted { $0.start < $1.start }
    if !meetings.isEmpty {
      lines += ["", "## Meetings"]
      for meeting in meetings { lines += describe(meeting, ref: ref(meeting), calendar: calendar, trim: trim) }
    }
    let notes = events.filter { $0.source == .note }.sorted { $0.start < $1.start }
    if !notes.isEmpty {
      lines += ["", "## Notes"]
      for note in notes { lines += describe(note, ref: ref(note), calendar: calendar, trim: trim) }
    }
    return JournalDigest(text: lines.joined(separator: "\n"), refs: refs, projects: projects)
  }

  private static func describe(_ event: JournalEvent, ref: String, calendar: Calendar, trim: Trim) -> [String] {
    let detail = event.detail
    let time = clock(event.start, calendar)
    let until = event.end.map { "–" + clock($0, calendar) } ?? ""
    switch event.source {
    case .claude:
      var lines = ["\(ref) Claude Code session \(time)\(until) · \(detail.activeMinutes ?? 0) active min"
        + (detail.branch.map { " · branch \($0)" } ?? "") + " · \"\(event.title)\""]
      let prompts = detail.prompts ?? []
      if !prompts.isEmpty {
        lines.append("  Asked:")
        if trim.prompts && prompts.count > 20 {
          lines += prompts.prefix(10).map { "  - \($0)" }
          lines.append("  - … \(prompts.count - 20) more prompts")
          lines += prompts.suffix(10).map { "  - \($0)" }
        } else {
          lines += prompts.map { "  - \($0)" }
        }
      }
      if !trim.files, let files = detail.files, !files.isEmpty {
        lines.append("  Files changed: " + files.joined(separator: ", "))
      }
      return lines
    case .git:
      var stat = ""
      if let files = detail.filesChanged {
        stat = " (+\(detail.insertions ?? 0) −\(detail.deletions ?? 0), \(files) file\(files == 1 ? "" : "s"))"
      }
      return ["\(ref) Commit \(time) \"\(event.title)\"\(stat)"]
    case .pr:
      return ["\(ref) Pull request \(detail.action ?? "opened") \(time): #\(detail.number ?? 0) \"\(event.title)\""
        + (detail.repository.map { " (\($0))" } ?? "")]
    case .review:
      let state = (detail.reviewState ?? "commented").replacingOccurrences(of: "_", with: " ")
      let comments = detail.comments ?? 0
      return ["\(ref) Review (\(state), \(comments) comment\(comments == 1 ? "" : "s")) \(time): "
        + "#\(detail.number ?? 0) \"\(event.title)\"" + (detail.repository.map { " (\($0))" } ?? "")]
    case .meeting:
      return ["\(ref) \(time)\(until) \(event.title)" + (detail.calendar.map { " (\($0))" } ?? "")
        + (detail.notes.map { " — notes: \($0)" } ?? "")]
    case .note:
      return ["\(ref) \(time) \(event.title)"]
    }
  }

  /// "10:05", 24-hour, in the calendar's time zone.
  static func clock(_ date: Date, _ calendar: Calendar) -> String {
    let parts = calendar.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
  }

  /// "Friday 9 October 2026".
  static func longDate(_ day: JournalDay, calendar: Calendar) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "EEEE d MMMM yyyy"
    return formatter.string(from: day.start(in: calendar).addingTimeInterval(12 * 3600))
  }
}
