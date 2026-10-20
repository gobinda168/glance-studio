import Foundation

/// A stretch of time at work: a run of Claude messages, commands in a terminal, a commit's last minutes, a meeting.
public struct JournalSpan: Codable, Hashable, Sendable {
  public var start: Date
  public var end: Date

  public init(start: Date, end: Date) {
    self.start = start
    self.end = max(start, end)
  }

  public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// The interval maths Journal's time figures rest on (spec "Analytics math").
public enum JournalSpans {
  /// Moments of activity joined into spans: moments at most `gap` apart share a span. A span shorter than `minimum`
  /// (a lone message) is stretched to `minimum`.
  public static func join(_ points: [Date], gap: TimeInterval, minimum: TimeInterval = 60) -> [JournalSpan] {
    let sorted = points.sorted()
    guard let first = sorted.first else { return [] }
    var spans: [JournalSpan] = []
    var start = first
    var last = first
    for point in sorted.dropFirst() {
      if point.timeIntervalSince(last) > gap {
        spans.append(JournalSpan(start: start, end: max(last, start.addingTimeInterval(minimum))))
        start = point
      }
      last = point
    }
    spans.append(JournalSpan(start: start, end: max(last, start.addingTimeInterval(minimum))))
    return union(spans)
  }

  /// Overlapping or touching spans merged, oldest first; empty spans dropped.
  public static func union(_ spans: [JournalSpan]) -> [JournalSpan] {
    var merged: [JournalSpan] = []
    for span in spans.sorted(by: { $0.start < $1.start }) where span.duration > 0 {
      if let last = merged.last, span.start <= last.end {
        merged[merged.count - 1].end = max(last.end, span.end)
      } else {
        merged.append(span)
      }
    }
    return merged
  }

  /// `spans` with every moment of `minus` taken out.
  public static func subtract(_ spans: [JournalSpan], _ minus: [JournalSpan]) -> [JournalSpan] {
    let cuts = union(minus)
    return union(spans).flatMap { span -> [JournalSpan] in
      var pieces = [span]
      for cut in cuts where cut.end > span.start && cut.start < span.end {
        pieces = pieces.flatMap { piece -> [JournalSpan] in
          guard cut.end > piece.start, cut.start < piece.end else { return [piece] }
          var parts: [JournalSpan] = []
          if cut.start > piece.start { parts.append(JournalSpan(start: piece.start, end: cut.start)) }
          if cut.end < piece.end { parts.append(JournalSpan(start: cut.end, end: piece.end)) }
          return parts
        }
      }
      return pieces
    }
  }

  /// The parts of `spans` inside `interval`.
  public static func clip(_ spans: [JournalSpan], to interval: DateInterval) -> [JournalSpan] {
    spans.compactMap { span in
      let start = max(span.start, interval.start)
      let end = min(span.end, interval.end)
      return end > start ? JournalSpan(start: start, end: end) : nil
    }
  }

  /// The time `spans` cover, overlaps counted once.
  public static func total(_ spans: [JournalSpan]) -> TimeInterval {
    union(spans).reduce(0) { $0 + $1.duration }
  }

  /// `total` in whole minutes, rounded.
  public static func minutes(_ spans: [JournalSpan]) -> Int {
    Int((total(spans) / 60).rounded())
  }
}
