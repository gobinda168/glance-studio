import Foundation

/// A trigger's glyph in a side bar row and in Setup (spec "The UI": clock / folder / bolt / eye for a watcher).
public enum AutomationTriggerGlyph: String, Equatable, Sendable {
  case clock, folder, bolt, eye
}

/// How a state reads: the tone picks a glyph and its colour; words always go with it.
public enum AutomationTone: Equatable, Sendable {
  case neutral, running, waiting, ok, failed
}

/// The line under an automation's name in the side bar.
public struct AutomationRowStatus: Equatable, Sendable {
  public var tone: AutomationTone
  public var text: String

  public init(tone: AutomationTone, text: String) {
    self.tone = tone
    self.text = text
  }
}

/// A "Needs you" row: what's waiting and what to do about it.
public struct AutomationNeedLine: Equatable, Sendable {
  public var title: String
  public var detail: String
  public var tone: AutomationTone

  public init(title: String, detail: String, tone: AutomationTone) {
    self.title = title
    self.detail = detail
    self.tone = tone
  }
}

/// How the Automations side bar reads (spec "The UI"): a row's trigger glyphs and status line, Needs you, the
/// Library in name order or ranked by search (the same ranking as the MCP's `automations_search`).
public enum AutomationText {
  public static func glyph(_ trigger: AutomationTrigger) -> AutomationTriggerGlyph? {
    switch trigger.typed {
    case .schedule: .clock
    case .files: .folder
    case .event: .bolt
    case .watcher: .eye
    case .manual, nil: nil
    }
  }

  /// One glyph per kind of trigger, in the order they first appear; manual has none.
  public static func glyphs(_ manifest: AutomationManifest?) -> [AutomationTriggerGlyph] {
    var glyphs: [AutomationTriggerGlyph] = []
    for item in (manifest?.triggers ?? []).compactMap({ glyph($0) }) where !glyphs.contains(item) {
      glyphs.append(item)
    }
    return glyphs
  }

  /// A library card's trigger chip: the schedule's cron, the folder watched, the event's name, the watcher's script
  /// (and how often); manual has none.
  public static func chip(_ trigger: AutomationTrigger) -> String? {
    switch trigger.typed {
    case .schedule: trigger.cron
    case .files: trigger.path.map { $0 + (trigger.glob.map { " (\($0))" } ?? "") }
    case .event: trigger.name
    case .watcher:
      trigger.script.map { ($0 as NSString).lastPathComponent + (trigger.every.map { " every \($0)" } ?? "") }
    case .manual, nil: nil
    }
  }

  /// A card's chips with their glyphs, in the manifest's order, at most `limit`.
  public static func chips(_ manifest: AutomationManifest?, limit: Int = 2) -> [(glyph: AutomationTriggerGlyph, text: String)] {
    (manifest?.triggers ?? []).compactMap { trigger in
      guard let glyph = glyph(trigger), let text = chip(trigger), !text.isEmpty else { return nil }
      return (glyph, text)
    }.prefix(limit).map { $0 }
  }

  /// "just now", "5 min ago", "3 h ago", "2 d ago" (a date in the future is "just now").
  public static func ago(_ date: Date, now: Date) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    switch seconds {
    case ..<60: return "just now"
    case ..<3600: return "\(Int(seconds / 60)) min ago"
    case ..<86_400: return "\(Int(seconds / 3600)) h ago"
    default: return "\(Int(seconds / 86_400)) d ago"
    }
  }

  /// A run going comes first (waiting, or the step it's on), then broken, a stopped watcher, an approval lost to a
  /// change, the last run, and for one never run whether it still needs approving.
  public static func row(_ entry: AutomationEntry, live: AutomationLiveRun?, now: Date) -> AutomationRowStatus {
    if let live {
      if live.parked {
        return AutomationRowStatus(tone: .waiting, text: "Waiting for you" + (live.step.map { " at \($0)" } ?? ""))
      }
      return AutomationRowStatus(tone: .running, text: "Running" + (live.step.map { " \($0)" } ?? ""))
    }
    if let broken = entry.brokenLine { return AutomationRowStatus(tone: .failed, text: broken) }
    if entry.brokenWatcher != nil { return AutomationRowStatus(tone: .failed, text: "Watcher stopped") }
    if case .changed = entry.approval { return AutomationRowStatus(tone: .waiting, text: "Changed: approve it again") }
    // Not approved (a new package, or one restored from history) outranks its last run: it isn't armed.
    if entry.approval == .never { return AutomationRowStatus(tone: .waiting, text: "Not approved yet") }
    if let run = entry.lastRun {
      let when = ago(run.startedAt, now: now)
      switch run.status {
      case .ok: return AutomationRowStatus(tone: .ok, text: "Ran \(when)")
      case .failed: return AutomationRowStatus(tone: .failed, text: "Failed \(when)")
      case .expired: return AutomationRowStatus(tone: .failed, text: "Expired \(when)")
      case .interrupted: return AutomationRowStatus(tone: .failed, text: "Interrupted \(when)")
      case .cancelled: return AutomationRowStatus(tone: .neutral, text: "Cancelled \(when)")
      case .running, .parked: return AutomationRowStatus(tone: .running, text: "Started \(when)")
      }
    }
    return AutomationRowStatus(tone: .neutral, text: "Never run")
  }

  /// A Needs you row for `need` of the automation called `name`.
  public static func need(_ need: AutomationNeed, name: String) -> AutomationNeedLine {
    switch need {
    case .parked(_, let step):
      return AutomationNeedLine(title: "\(name) is waiting", detail: "Approve or skip \(step)", tone: .waiting)
    case .question(_, let question):
      return AutomationNeedLine(title: "\(name) is asking you", detail: question.question, tone: .waiting)
    case .approval(_, let lines):
      return AutomationNeedLine(title: "Approve \(name)", detail: lines.first ?? "", tone: .waiting)
    case .brokenWatcher(_, let stderr):
      let last = stderr.split(separator: "\n")
        .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        .map(String.init)
      return AutomationNeedLine(title: "\(name)'s watcher stopped",
                                detail: last ?? "It crashed 5 times in 10 minutes.", tone: .failed)
    case .broken(_, let problem):
      return AutomationNeedLine(title: "\(name) is broken", detail: problem, tone: .failed)
    }
  }

  /// The entries of one side bar: agents, or (with `agents` false) the rest. A broken one with no manifest is never an
  /// agent. With Agents off (`separate` false) the Automations side bar lists everything.
  public static func only(_ entries: [AutomationEntry], agents: Bool, separate: Bool = true) -> [AutomationEntry] {
    guard separate else { return agents ? [] : entries }
    return entries.filter { ($0.manifest?.isAgent ?? false) == agents }
  }

  /// The Library: every automation by name, or, while searching, the ranked matches followed by broken packages
  /// whose folder name contains the query (they have no manifest to search).
  public static func library(_ entries: [AutomationEntry], query: String) -> [AutomationEntry] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return entries.sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
    }
    let searchable = entries.compactMap { entry in
      entry.manifest.map { AutomationSearchEntry(manifest: $0, readme: entry.readme) }
    }
    var found = AutomationSearch.rank(trimmed, in: searchable, limit: 100).compactMap { hit in
      entries.first { $0.id == hit.id }
    }
    let lowered = trimmed.lowercased()
    found += entries.filter { $0.manifest == nil && $0.id.contains(lowered) }
    return found
  }
}
