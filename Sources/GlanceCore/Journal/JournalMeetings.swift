import Foundation

/// The meetings that count for Journal (spec 2026-10-09-journal-design.md, "Capture"): not declined, not all-day,
/// on a ticked calendar, at least five minutes long.
public enum JournalMeetings {
  public static let shortest: TimeInterval = 5 * 60

  public static func events(_ meetings: [MeetingEvent], calendarsOff: Set<String>, range: DateInterval,
                            calendar: Calendar, notes: [String: String] = [:]) -> [JournalEvent] {
    meetings
      .filter { meeting in
        !meeting.declined && !meeting.isAllDay && !calendarsOff.contains(meeting.calendarID)
          && meeting.end.timeIntervalSince(meeting.start) >= shortest
          && meeting.start >= range.start && meeting.start < range.end
      }
      .map { meeting in
        JournalEvent(source: .meeting, externalID: meeting.id, day: JournalDay(meeting.start, calendar: calendar),
                     start: meeting.start, end: meeting.end, title: JournalText.clean(meeting.title, limit: 200),
                     detail: JournalDetail(calendar: meeting.calendarTitle, notes: notes[meeting.id]))
      }
  }

  /// Recorded meetings' notes by their calendar occurrence (`MeetingEvent.id`): the overview and the user's action
  /// items, for the meeting's Journal event.
  public static func notes(_ records: [MeetingRecord]) -> [String: String] {
    var out: [String: String] = [:]
    for record in records {
      if let eventID = record.eventID, let text = noteText(record) { out[eventID] = text }
    }
    return out
  }

  /// Meetings recorded with no calendar event on Journal's list become events of their own, with their notes.
  public static func recorded(_ records: [MeetingRecord], calendarEventIDs: Set<String>, range: DateInterval,
                              calendar: Calendar) -> [JournalEvent] {
    records
      .filter { record in
        record.status == .ready && !(record.eventID.map(calendarEventIDs.contains) ?? false)
          && record.start >= range.start && record.start < range.end
      }
      .map { record in
        JournalEvent(source: .meeting, externalID: "notes:\(record.id)", day: JournalDay(record.start, calendar: calendar),
                     start: record.start, end: record.end, title: JournalText.clean(record.title, limit: 200),
                     detail: JournalDetail(notes: noteText(record)))
      }
  }

  static func noteText(_ record: MeetingRecord) -> String? {
    guard let summary = record.summary else { return nil }
    var text = summary.overview
    let mine = summary.actionItems.filter(\.mine).map(\.task)
    if !mine.isEmpty { text += " Mine: " + mine.joined(separator: "; ") + "." }
    return JournalText.clean(text, limit: 600)
  }
}

/// Terminal activity as time per project (spec "Capture", terminal history): only when, never what. Runs in a git
/// repository count; imported zsh history (no times worth trusting) doesn't.
public enum JournalTerminal {
  public static func spans(_ records: [CommandRecord], calendar: Calendar) -> [JournalDay: [String: [JournalSpan]]] {
    var points: [JournalDay: [String: [Date]]] = [:]
    for record in records where !record.imported {
      guard let project = record.gitRoot else { continue }
      let day = JournalDay(record.start, calendar: calendar)
      points[day, default: [:]][project, default: []] +=
        [record.start, record.start.addingTimeInterval(max(0, record.duration ?? 0))]
    }
    return points.mapValues { projects in projects.mapValues { JournalSpans.join($0, gap: JournalTranscripts.gap) } }
  }
}
