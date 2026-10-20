import Foundation

/// One event on Glance's in-process bus (spec "Trigger sources", *event*): a name from `AutomationEvents` and its
/// payload. Build them with the constructors below, so the fields always match the catalogue.
public struct GlanceEvent: Equatable, Sendable {
  public var name: String
  public var payload: AutomationValue

  public init(name: String, payload: AutomationValue) {
    self.name = name
    self.payload = payload
  }

  public static func meetingEnded(meetingID: String, title: String, notesPath: String) -> GlanceEvent {
    GlanceEvent(name: "meeting.ended", payload: .object([
      "meetingID": .string(meetingID), "title": .string(title), "notesPath": .string(notesPath),
    ]))
  }

  public static func noticeNew(source: String, title: String, url: String) -> GlanceEvent {
    GlanceEvent(name: "notice.new", payload: .object([
      "source": .string(source), "title": .string(title), "url": .string(url),
    ]))
  }

  public static func ticketMoved(key: String, from: String, to: String) -> GlanceEvent {
    GlanceEvent(name: "ticket.moved", payload: .object(["key": .string(key), "from": .string(from), "to": .string(to)]))
  }

  public static func prCIFailed(repo: String, number: Int, sha: String) -> GlanceEvent {
    GlanceEvent(name: "pr.ci.failed", payload: .object([
      "repo": .string(repo), "number": .number(Double(number)), "sha": .string(sha),
    ]))
  }

  public static func agentMessage(from: String, to: String, text: String, hops: Int) -> GlanceEvent {
    GlanceEvent(name: "agent.message", payload: .object([
      "from": .string(from), "to": .string(to), "text": .string(text), "hops": .number(Double(hops)),
    ]))
  }

  public static func journalClosed(date: String) -> GlanceEvent {
    GlanceEvent(name: "journal.closed", payload: .object(["date": .string(date)]))
  }
}

/// When the five first publishers publish (spec "Trigger sources": the first publishers).
public enum AutomationEventSignals {
  /// notice.new for a notice that just arrived — except Automations' own cards: an automation on notice.new would
  /// otherwise start itself again with every card it posts.
  public static func noticeNew(_ notice: Notice) -> GlanceEvent? {
    guard notice.source != .automations else { return nil }
    return .noticeNew(source: notice.source.rawValue, title: notice.title, url: url(notice.target))
  }

  /// A link for the payload (data for a step, never opened by Glance): the PR or issue on GitHub, a web page, a
  /// meeting's join link; "" otherwise.
  static func url(_ target: Notice.Target) -> String {
    switch target {
    case .pullRequest(let repository, let number, _, _): "https://github.com/\(repository)/pull/\(number)"
    case .issue(let repository, let number): "https://github.com/\(repository)/issues/\(number)"
    case .link(let url): url.absoluteString
    case .meeting(_, let joinURL): joinURL?.absoluteString ?? ""
    case .slack, .terminal, .none: ""
    }
  }

  /// meeting.ended when the recorder's meeting turns ready with notes — once per meeting (`fired` remembers).
  public static func meetingEnded(_ record: MeetingRecord?, notesPath: String,
                                  fired: inout Set<String>) -> GlanceEvent? {
    guard let record, record.status == .ready, record.summary != nil, !fired.contains(record.id) else { return nil }
    fired.insert(record.id)
    return .meetingEnded(meetingID: record.id, title: record.title, notesPath: notesPath)
  }

  /// journal.closed the first time a day's recap is drafted (a redraft of a drafted or reviewed day isn't a close).
  public static func journalClosed(day: JournalDay, before: JournalDayRecord.Status) -> GlanceEvent? {
    before == .open || before == .failed ? .journalClosed(date: day.key) : nil
  }
}

/// pr.ci.failed from the pull request pages Studio loads: once per head commit, when its checks turn failing after
/// Studio saw them not failing — the first look at a pull request never fires (like a schedule's catch-up rule), so
/// opening an old red pull request doesn't start anything.
public struct CIFailureTracker: Sendable {
  struct Seen: Sendable {
    var sha: String
    var failing: Bool
  }

  var seen: [String: Seen] = [:]
  var fired: Set<String> = []

  public init() {}

  public mutating func observe(repo: String, number: Int, sha: String, failing: Bool) -> GlanceEvent? {
    let key = "\(repo)#\(number)"
    let before = seen[key]
    seen[key] = Seen(sha: sha, failing: failing)
    guard failing, let before else { return nil }
    guard before.sha != sha || !before.failing else { return nil }
    guard fired.insert("\(key)@\(sha)").inserted else { return nil }
    return .prCIFailed(repo: repo, number: number, sha: sha)
  }
}

/// notes.md beside a meeting's meeting.json: what meeting.ended's `notesPath` points at.
public enum MeetingNotesMarkdown {
  public static let fileName = "notes.md"

  public static func render(_ record: MeetingRecord, calendar: Calendar = .current) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    var lines = ["# \(record.title)", "", formatter.string(from: record.start), ""]
    if let summary = record.summary {
      lines += ["## Overview", "", summary.overview, ""]
      if !summary.decisions.isEmpty { lines += ["## Decisions", ""] + summary.decisions.map { "- \($0)" } + [""] }
      if !summary.actionItems.isEmpty {
        lines += ["## Action items", ""]
        lines += summary.actionItems.map { item in "- " + item.task + (item.owner.map { " (\($0))" } ?? "") }
        lines.append("")
      }
      if !summary.openQuestions.isEmpty {
        lines += ["## Open questions", ""] + summary.openQuestions.map { "- \($0)" } + [""]
      }
    }
    if !record.lines.isEmpty {
      lines += ["## Transcript", ""]
      lines += record.lines.map { line in "**\(speaker(line.speaker, in: record)):** \(line.text)" }
      lines.append("")
    }
    return lines.joined(separator: "\n")
  }

  static func speaker(_ label: String, in record: MeetingRecord) -> String {
    if let name = record.speakerNames[label], !name.isEmpty { return name }
    return label == TranscriptLine.you ? "You" : label
  }
}
