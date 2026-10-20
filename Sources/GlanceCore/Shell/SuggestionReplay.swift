import Foundation

/// The replay check (spec "S3", "Replay check"): Glance's own history played back in order, asking at each run what
/// the ghost text would have offered after 1, 2 and 3 typed characters and what the next-command prediction would
/// have said, against what was actually run. It tunes the weights; nothing leaves the Mac.
public enum SuggestionReplay {
  public struct Tally: Equatable, Sendable {
    public var asked = 0
    public var offered = 0
    public var right = 0
  }

  public struct Report: Equatable, Sendable {
    public var runs = 0
    public var recorded = 0
    /// Typed characters (1, 2, 3) → how it went.
    public var ghost: [Int: Tally] = [:]
    public var next = Tally()
  }

  /// `records` oldest first. Paths are taken to exist (the folders of old runs may be gone).
  public static func run(_ records: [CommandRecord], weights: GhostSuggester.Weights = .standard) -> Report {
    var report = Report()
    var index = CommandIndex()
    var previous: [String: (command: String, start: Date)] = [:]
    for record in records {
      defer { index.add(record) }
      let stream = record.tab ?? (record.imported ? "" : "?")
      defer { previous[stream] = (record.command, record.start) }
      guard !record.command.contains("\n"), HistoryPolicy.shouldRecord(record.command) else { continue }
      report.runs += 1
      if !record.imported { report.recorded += 1 }
      let before = previous[stream].flatMap { record.start.timeIntervalSince($0.start) < CommandIndex.habitGap ? $0 : nil }
      for typed in 1...3 where record.command.count > typed {
        let line = String(record.command.prefix(typed))
        var context = GhostContext(line: line, folder: record.folder ?? "", tab: record.tab, previous: before?.command,
                                   now: record.start, names: [], exists: { _ in true }, list: { _ in nil })
        context.gitRoot = record.gitRoot
        report.ghost[typed, default: Tally()].asked += 1
        guard let suggestion = GhostSuggester.suggest(index, context, weights: weights) else { continue }
        report.ghost[typed]?.offered += 1
        if line + suggestion.text == record.command { report.ghost[typed]?.right += 1 }
      }
      if let before {
        report.next.asked += 1
        if let next = GhostSuggester.next(index, previous: before.command, folder: record.folder ?? "") {
          report.next.offered += 1
          if next.text == GhostSuggester.template(record.command).text { report.next.right += 1 }
        }
      }
    }
    return report
  }

  /// The report as the command line prints it.
  public static func describe(_ report: Report) -> String {
    func percent(_ part: Int, _ whole: Int) -> String {
      whole == 0 ? "–" : String(format: "%.0f%%", 100 * Double(part) / Double(whole))
    }
    var lines = ["Replayed \(report.runs) commands (\(report.recorded) recorded in Studio, \(report.runs - report.recorded) "
      + "imported)."]
    for typed in 1...3 {
      let tally = report.ghost[typed] ?? Tally()
      lines.append("Ghost text after \(typed) typed character\(typed == 1 ? "" : "s"): offered \(percent(tally.offered, tally.asked)), "
        + "right \(percent(tally.right, tally.asked)) of runs (\(percent(tally.right, tally.offered)) of what it offered).")
    }
    lines.append("Next command: offered \(percent(report.next.offered, report.next.asked)), right "
      + "\(percent(report.next.right, report.next.asked)) (\(percent(report.next.right, report.next.offered)) of what it offered).")
    return lines.joined(separator: "\n")
  }
}
