import Foundation

/// How runs read in the automation tab (spec 2026-10-09-automations-design.md, "The UI": a run's status, trigger,
/// start, duration and cost; its answer under the form).
public enum AutomationRunText {
  public static func status(_ status: RunRecord.Status) -> String {
    switch status {
    case .running: "Running"
    case .parked: "Waiting for you"
    case .ok: "Done"
    case .failed: "Failed"
    case .cancelled: "Cancelled"
    case .expired: "Expired"
    case .interrupted: "Interrupted"
    }
  }

  public static func tone(_ status: RunRecord.Status) -> AutomationTone {
    switch status {
    case .running: .running
    case .parked: .waiting
    case .ok: .ok
    case .failed, .expired, .interrupted: .failed
    case .cancelled: .neutral
    }
  }

  public static func stepStatus(_ status: RunRecord.StepStatus) -> String {
    switch status {
    case .running: "Running"
    case .ok: "Done"
    case .failed: "Failed"
    case .skipped: "Skipped"
    case .cancelled: "Cancelled"
    }
  }

  /// "320 ms", "4.2 s", "3 min 5 s", "1 h 4 min"; "" without one.
  public static func duration(_ ms: Int?) -> String {
    guard let ms else { return "" }
    if ms < 1000 { return "\(ms) ms" }
    if ms < 60_000 { return String(format: "%.1f s", Double(ms) / 1000) }
    let seconds = ms / 1000
    if seconds < 3600 { return "\(seconds / 60) min \(seconds % 60) s" }
    return "\(seconds / 3600) h \(seconds % 3600 / 60) min"
  }

  /// Claude's cost as Usage writes it; "" when nothing was spent.
  public static func cost(_ dollars: Double) -> String {
    dollars > 0 ? UsageFormat.cost(dollars) : ""
  }

  /// The run log's trigger line in words: "By hand", "From morning-digest", "Schedule 0 9 * * 1-5".
  public static func trigger(_ summary: String) -> String {
    if summary == "manual" { return "By hand" }
    if summary.hasPrefix("automation ") { return "From \(summary.dropFirst("automation ".count))" }
    return summary.prefix(1).uppercased() + summary.dropFirst()
  }

  /// The run's answer: the failed step's text when it failed, else the last step that said something.
  public static func result(_ record: RunRecord) -> String? {
    let step = record.status == .failed
      ? record.steps.last { $0.status == .failed }
      : record.steps.last { $0.status == .ok && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    let text = step?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return text.isEmpty ? nil : text
  }

  /// A step prints up to 1 MB; the tab shows its last 20 000 characters (the log has it all).
  public static let tailLimit = 20_000

  public static func tail(_ text: String) -> String {
    text.count > tailLimit ? "…" + text.suffix(tailLimit) : text
  }
}

/// One step of a run's timeline in the Runs view.
public struct AutomationTimelineStep: Equatable, Identifiable, Sendable {
  public enum Phase: Equatable, Sendable {
    case notRun, running, waiting, ok, failed, skipped, cancelled
  }

  public var id: String
  public var phase: Phase
  /// "Done in 1.2 s, $0.04", "Waiting for you", "Not run".
  public var line: String
  /// Claude's tool calls, counted: "Bash ×3", "Edit".
  public var tools: [String]
  /// Its result (step.end's text).
  public var text: String
  /// Everything it printed, when that's more than its result.
  public var output: String?
  public var tone: AutomationTone
  /// What kind of step it is in the manifest (nil when the manifest no longer has it): the agent page tags Claude
  /// steps "Claude" and ask steps "You".
  public var kind: Kind? = nil
  /// An ask step's question, and the answer once given.
  public var question: AutomationQuestion? = nil
  public var answer: AutomationAnswer? = nil

  public enum Kind: Equatable, Sendable { case script, claude, automation, ask }
}

public enum AutomationTimeline {
  /// The run's steps as the log has them; the step it waits at; then, when the manifest is the version that ran, the
  /// steps it hasn't reached ("Not started" while it goes, "Not run" once it ended).
  public static func steps(_ record: RunRecord, manifest: AutomationManifest?) -> [AutomationTimelineStep] {
    var rows = record.steps.map(row)
    if record.status == .parked, let parked = record.parkedAt {
      if let index = rows.firstIndex(where: { $0.id == parked }) {
        // An ask step waiting: started, not running.
        if record.question != nil {
          rows[index].phase = .waiting
          rows[index].tone = .waiting
          rows[index].line = "Waiting for you"
        }
      } else {
        rows.append(AutomationTimelineStep(id: parked, phase: .waiting, line: "Waiting for you", tools: [], text: "",
                                           output: nil, tone: .waiting))
      }
    }
    if let manifest {
      for index in rows.indices {
        rows[index].kind = manifest.steps.first { $0.id == rows[index].id }.flatMap(kind)
      }
    }
    guard let manifest, manifest.version == record.version else { return rows }
    let line = record.endedAt == nil ? "Not started" : "Not run"
    for step in manifest.steps where !rows.contains(where: { $0.id == step.id }) {
      rows.append(AutomationTimelineStep(id: step.id, phase: .notRun, line: line, tools: [], text: "", output: nil,
                                         tone: .neutral, kind: kind(step)))
    }
    return rows
  }

  static func kind(_ step: AutomationStep) -> AutomationTimelineStep.Kind? {
    switch step.kind {
    case .script, .command: .script
    case .claude: .claude
    case .automation: .automation
    case .ask: .ask
    case nil: nil
    }
  }

  /// "Answered", "Answered by voice", "Answered in words".
  public static func answered(_ answer: AutomationAnswer) -> String {
    switch answer.via {
    case .click: "Answered"
    case .voice: "Answered by voice"
    case .text: "Answered in words"
    }
  }

  static func row(_ step: RunRecord.Step) -> AutomationTimelineStep {
    let (phase, tone): (AutomationTimelineStep.Phase, AutomationTone) = switch step.status {
    case .running: (.running, .running)
    case .ok: (.ok, .ok)
    case .failed: (.failed, .failed)
    case .skipped: (.skipped, .neutral)
    case .cancelled: (.cancelled, .neutral)
    }
    var line = AutomationRunText.stepStatus(step.status)
    let duration = AutomationRunText.duration(step.durationMs)
    if !duration.isEmpty { line += " in \(duration)" }
    let cost = AutomationRunText.cost(step.costUSD ?? 0)
    if !cost.isEmpty { line += ", \(cost)" }
    if let answer = step.answer, step.status == .ok { line = answered(answer) }
    let text = step.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let output = step.output.trimmingCharacters(in: .whitespacesAndNewlines)
    return AutomationTimelineStep(id: step.id, phase: phase, line: line, tools: counted(step.tools), text: text,
                                  output: output.isEmpty || output == text ? nil : step.output, tone: tone,
                                  question: step.question, answer: step.answer)
  }

  /// "Bash", "Edit", "Bash" → "Bash ×2", "Edit" (first call's order).
  public static func counted(_ tools: [String]) -> [String] {
    var order: [String] = []
    var counts: [String: Int] = [:]
    for tool in tools {
      if counts[tool] == nil { order.append(tool) }
      counts[tool, default: 0] += 1
    }
    return order.map { tool in
      let count = counts[tool] ?? 1
      return count > 1 ? "\(tool) ×\(count)" : tool
    }
  }
}

/// How Setup's History reads (A1's commits: "Save <name> (<id>) v4", "Restore … v2 from abc1234 as v5",
/// "Delete …").
public enum AutomationHistoryText {
  public static func title(_ entry: AutomationHistoryEntry) -> String {
    if let version = entry.version { return "Version \(version)" }
    return entry.message.hasPrefix("Delete ") ? "Deleted" : entry.shortCommit
  }

  /// "Saved 2 d ago", "Restored v2, 1 h ago", "Deleted just now".
  public static func detail(_ entry: AutomationHistoryEntry, now: Date) -> String {
    let when = AutomationText.ago(entry.date, now: now)
    let message = entry.message
    if message.hasPrefix("Save ") { return "Saved \(when)" }
    if message.hasPrefix("Restore "), let from = message.range(of: " from ", options: .backwards),
       let restored = message[..<from.lowerBound].split(separator: " ").last {
      return "Restored \(restored), \(when)"
    }
    if message.hasPrefix("Delete ") { return "Deleted \(when)" }
    return "\(message), \(when)"
  }

  /// Restore is on every older version: not the one in use (the first), not a delete.
  public static func canRestore(_ entries: [AutomationHistoryEntry], at index: Int) -> Bool {
    index > 0 && entries.indices.contains(index) && entries[index].version != nil
  }

  /// After a delete (the newest entry), the version Undo brings back: the newest one before it.
  public static func undoTarget(_ entries: [AutomationHistoryEntry]) -> AutomationHistoryEntry? {
    guard let first = entries.first, first.message.hasPrefix("Delete ") else { return nil }
    return entries.dropFirst().first { $0.version != nil }
  }
}

/// A trigger in Setup: its glyph, what kind it is, and its details.
public struct AutomationTriggerLine: Equatable, Sendable {
  public var glyph: AutomationTriggerGlyph?
  public var title: String
  public var detail: String

  public init(glyph: AutomationTriggerGlyph?, title: String, detail: String) {
    self.glyph = glyph
    self.title = title
    self.detail = detail
  }
}

/// How Setup reads: each trigger (a schedule with its next time), whether the triggers are on, the approval state.
public enum AutomationSetupText {
  public static func trigger(_ trigger: AutomationTrigger, now: Date, calendar: Calendar) -> AutomationTriggerLine {
    let glyph = AutomationText.glyph(trigger)
    switch trigger.typed {
    case .manual:
      return AutomationTriggerLine(glyph: nil, title: "By hand", detail: "From this tab, the side bar, or Claude")
    case .schedule:
      let cron = trigger.cron ?? ""
      var detail = cron
      if let schedule = try? CronSchedule(parsing: cron), let next = schedule.next(after: now, calendar: calendar) {
        detail += ", next \(nextText(next, calendar: calendar))"
      }
      return AutomationTriggerLine(glyph: glyph, title: "Schedule", detail: detail)
    case .files:
      let detail = (trigger.path ?? "") + (trigger.glob.map { ", matching \($0)" } ?? "")
      return AutomationTriggerLine(glyph: glyph, title: "Files", detail: detail)
    case .event:
      let filter = (trigger.filter ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value.text)" }
      let detail = (trigger.name ?? "") + (filter.isEmpty ? "" : ", when " + filter.joined(separator: " and "))
      return AutomationTriggerLine(glyph: glyph, title: "Glance event", detail: detail)
    case .watcher:
      let detail = (trigger.script ?? "") + (trigger.every.map { ", every \($0)" } ?? ", always running")
      return AutomationTriggerLine(glyph: glyph, title: "Watcher", detail: detail)
    case nil:
      return AutomationTriggerLine(glyph: nil, title: trigger.kind, detail: "Glance doesn't know this kind of trigger")
    }
  }

  /// "Thu 9 Oct 09:00" in the calendar's time zone.
  static func nextText(_ date: Date, calendar: Calendar) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "EEE d MMM HH:mm"
    return formatter.string(from: date)
  }

  /// Whether the triggers fire, and if not, why (spec "Engine": armed while enabled and approved).
  public static func armed(_ entry: AutomationEntry) -> String {
    let triggers = entry.manifest?.triggers.filter { $0.typed != .manual } ?? []
    if entry.manifest != nil, triggers.isEmpty { return "Runs only when you start it." }
    if entry.isBroken { return "Its triggers are off until the problems below are fixed." }
    if !entry.enabled { return "Its triggers are off: it's switched off." }
    if !entry.approval.isApproved { return "Its triggers are off until you approve this version." }
    return "Its triggers are on while Glance Studio runs."
  }

  public static func approval(_ entry: AutomationEntry) -> String {
    switch entry.approval {
    case .approved: "Approved"
    case .changed: "Changed since you approved it"
    case .never: "Not approved yet"
    }
  }
}
