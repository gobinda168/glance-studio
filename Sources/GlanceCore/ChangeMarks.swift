import Foundation

/// A run of lines the editor marks in its gutter. Lines are 1-based and inclusive.
public struct LineMark: Equatable, Sendable {
  public enum Kind: String, Sendable { case added, modified, deleted }

  public var start: Int
  public var end: Int
  public var kind: Kind

  public init(start: Int, end: Int, kind: Kind) {
    self.start = start
    self.end = end
    self.kind = kind
  }
}

/// Finds the lines Claude's edits changed in a file as it is now.
public enum ChangeMarks {
  public static func marks(in text: String, changes: [FileEdit.Change]) -> [LineMark] {
    let lineCount = text.unicodeScalars.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    var found: [LineMark] = []
    for change in changes {
      switch change {
      case .write:
        found.append(LineMark(start: 1, end: lineCount, kind: .modified))
      case .replace(let old, let new, _):
        found += locate(old: old, new: new, in: text, lineCount: lineCount)
      }
    }
    return merged(found)
  }

  /// Where `new` now sits in `text`, minus the lines `old` and `new` share at the top and bottom (Claude sends
  /// unchanged context lines so an edit is unique; they aren't changes).
  private static func locate(old: String, new: String, in text: String, lineCount: Int) -> [LineMark] {
    guard !new.isEmpty else { return [] }
    let oldLines = old.components(separatedBy: "\n")
    let newLines = new.components(separatedBy: "\n")
    var prefix = 0
    while prefix < min(oldLines.count, newLines.count), oldLines[prefix] == newLines[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < min(oldLines.count, newLines.count) - prefix,
          oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix] { suffix += 1 }
    let oldCore = oldLines.count - prefix - suffix
    let newCore = newLines.count - prefix - suffix
    if oldCore == 0, newCore == 0 { return [] }

    var result: [LineMark] = []
    var searchFrom = text.startIndex
    while let range = text.range(of: new, range: searchFrom..<text.endIndex) {
      let blockLine = 1 + text.unicodeScalars[..<range.lowerBound].reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
      if newCore > 0 {
        let start = blockLine + prefix
        result.append(LineMark(start: start, end: min(start + newCore - 1, lineCount), kind: oldCore == 0 ? .added : .modified))
      } else {
        let line = min(blockLine + prefix, lineCount)
        result.append(LineMark(start: line, end: line, kind: .deleted))
      }
      searchFrom = range.upperBound
    }
    return result
  }

  /// Sorted, with touching or overlapping runs of the same kind joined.
  private static func merged(_ marks: [LineMark]) -> [LineMark] {
    var result: [LineMark] = []
    for mark in marks.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
      if let last = result.last, last.kind == mark.kind, last.kind != .deleted, mark.start <= last.end + 1 {
        result[result.count - 1].end = max(last.end, mark.end)
      } else if result.last != mark {
        result.append(mark)
      }
    }
    return result
  }
}
