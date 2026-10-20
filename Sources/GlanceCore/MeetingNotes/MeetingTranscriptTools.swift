import Foundation

/// Drops the mic lines that are only the call coming back through the speakers (spec
/// 2026-10-09-meeting-notes-design.md, "EchoFilter"): a mic line that overlaps a call line in time and repeats most
/// of its words.
public enum EchoFilter {
  /// How far apart in time two lines may be and still be one being the echo of the other.
  static let slack: Double = 1.5
  static let overlap: Double = 0.6

  public static func filter(_ lines: [TranscriptLine]) -> [TranscriptLine] {
    let calls = lines.filter { $0.channel == .system }
    return lines.filter { line in
      guard line.channel == .mic else { return true }
      let words = Self.words(line.text)
      guard words.count >= 2 else {
        // A one-word mic line inside a call line saying it too is echo.
        return !calls.contains { near(line, $0) && Self.words($0.text).isSuperset(of: words) && !words.isEmpty }
      }
      return !calls.contains { call in
        guard near(line, call) else { return false }
        let callWords = Self.words(call.text)
        return Double(words.intersection(callWords).count) / Double(words.count) >= overlap
      }
    }
  }

  private static func near(_ a: TranscriptLine, _ b: TranscriptLine) -> Bool {
    a.start < b.end + slack && b.start < a.end + slack
  }

  static func words(_ text: String) -> Set<String> {
    Set(text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init))
  }
}

/// Gives the call channel's lines the diarizer's speakers (spec "SpeakerLabels"): each line takes the speaker it
/// overlaps most, and speakers are numbered S1, S2… in the order they first speak. Lines with no overlap take the
/// nearest span's speaker; with no spans at all they stay "others".
public enum SpeakerLabels {
  public struct Span: Equatable, Sendable {
    public let speaker: String
    public let start: Double
    public let end: Double

    public init(speaker: String, start: Double, end: Double) {
      self.speaker = speaker
      self.start = start
      self.end = end
    }
  }

  public static func assign(_ lines: [TranscriptLine], spans: [Span]) -> [TranscriptLine] {
    guard !spans.isEmpty else { return lines }
    var numbers: [String: Int] = [:]
    for span in spans.sorted(by: { $0.start < $1.start }) where numbers[span.speaker] == nil {
      numbers[span.speaker] = numbers.count + 1
    }
    return lines.map { line in
      guard line.channel == .system else { return line }
      var labelled = line
      let best = spans.max { overlap(line, $0) < overlap(line, $1) }
      let speaker: String?
      if let best, overlap(line, best) > 0 {
        speaker = best.speaker
      } else {
        speaker = spans.min { distance(line, $0) < distance(line, $1) }?.speaker
      }
      if let speaker, let number = numbers[speaker] { labelled.speaker = "S\(number)" }
      return labelled
    }
  }

  private static func overlap(_ line: TranscriptLine, _ span: Span) -> Double {
    max(0, min(line.end, span.end) - max(line.start, span.start))
  }

  private static func distance(_ line: TranscriptLine, _ span: Span) -> Double {
    span.end < line.start ? line.start - span.end : max(0, span.start - line.end)
  }
}

/// The transcript as text (spec "MeetingTranscript"): `[mm:ss] Name: words`, consecutive lines of one speaker merged.
public enum MeetingTranscript {
  public static func text(_ record: MeetingRecord, you: String = "You") -> String {
    merged(record.lines).map { line in
      "[\(clock(line.start))] \(record.name(of: line.speaker, you: you)): \(line.text)"
    }.joined(separator: "\n")
  }

  /// Lines in time order, a speaker's back-to-back lines (under 2 s apart) joined into one.
  public static func merged(_ lines: [TranscriptLine]) -> [TranscriptLine] {
    var out: [TranscriptLine] = []
    for line in lines.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
      let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { continue }
      if var last = out.last, last.speaker == line.speaker, line.start - last.end < 2 {
        last.text += " " + text
        last.end = max(last.end, line.end)
        out[out.count - 1] = last
      } else {
        var copy = line
        copy.text = text
        out.append(copy)
      }
    }
    return out
  }

  /// `m:ss`, or `h:mm:ss` from an hour.
  public static func clock(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
    return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
  }
}

/// Whether a meeting matches the side bar's search: every word of the query in its title, notes or transcript.
public enum MeetingSearch {
  public static func matches(_ record: MeetingRecord, query: String) -> Bool {
    let words = query.lowercased().split(whereSeparator: \.isWhitespace)
    guard !words.isEmpty else { return true }
    var haystack = record.title + " " + record.lines.map(\.text).joined(separator: " ")
    if let summary = record.summary {
      haystack += " " + summary.overview + " " + summary.decisions.joined(separator: " ")
        + " " + summary.actionItems.map { "\($0.owner ?? "") \($0.task)" }.joined(separator: " ")
        + " " + summary.openQuestions.joined(separator: " ")
    }
    haystack += " " + record.speakerNames.values.joined(separator: " ")
    let lowered = haystack.lowercased()
    return words.allSatisfy { lowered.contains($0) }
  }
}

/// The notes to share (spec "MeetingMarkdown"): Markdown that pastes well into Slack, Confluence or an email.
public enum MeetingMarkdown {
  public static func notes(_ record: MeetingRecord, you: String = "You") -> String {
    var parts: [String] = []
    let date = record.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year().hour().minute())
    let minutes = Int((record.duration() / 60).rounded())
    var header = "## \(record.title)\n\(date) · \(minutes) min"
    let people = record.speakers.map { record.name(of: $0, you: you) }
    if !people.isEmpty { header += " · " + people.joined(separator: ", ") }
    parts.append(header)
    if let summary = record.summary {
      parts.append("### Summary\n\(summary.overview)")
      if !summary.decisions.isEmpty {
        parts.append("### Decisions\n" + summary.decisions.map { "- \($0)" }.joined(separator: "\n"))
      }
      if !summary.actionItems.isEmpty {
        parts.append("### Action items\n" + summary.actionItems.map { item in
          "- [ ] " + (item.owner.map { "**\($0)**: " } ?? "") + item.task
        }.joined(separator: "\n"))
      }
      if !summary.openQuestions.isEmpty {
        parts.append("### Open questions\n" + summary.openQuestions.map { "- \($0)" }.joined(separator: "\n"))
      }
    } else if !record.lines.isEmpty {
      parts.append("### Transcript\n" + MeetingTranscript.text(record, you: you))
    }
    return parts.joined(separator: "\n\n") + "\n"
  }
}
