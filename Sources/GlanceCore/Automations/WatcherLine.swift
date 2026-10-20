import Foundation

/// One line a watcher script printed (spec "Trigger sources", *watcher*): a JSON object is an event (its fields are
/// `{{trigger.<field>}}`); anything else is logged and skipped.
public enum WatcherLine: Equatable, Sendable {
  case event(AutomationValue)
  /// Why it was skipped, for the run log.
  case skipped(String)

  public static func parse(_ line: String) -> WatcherLine {
    let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return .skipped("an empty line") }
    guard let value = AutomationValue.decode(Data(text.utf8)) else { return .skipped("not JSON: \(preview(text))") }
    guard value.object != nil else { return .skipped("not a JSON object: \(preview(text))") }
    return .event(value)
  }

  static func preview(_ text: String) -> String { text.count > 80 ? String(text.prefix(80)) + "…" : text }
}

/// Splits a watcher's stdout into lines as chunks arrive: "\n" or "\r\n" ends a line; a partial line waits for the
/// next chunk; a line longer than `limit` bytes is cut there (a runaway script can't grow memory).
public struct WatcherLineBuffer: Sendable {
  public static let limit = 64 * 1024

  var pending = Data()

  public init() {}

  public mutating func append(_ chunk: Data) -> [String] {
    pending.append(chunk)
    var lines: [String] = []
    while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
      lines.append(Self.text(pending[pending.startIndex..<newline]))
      pending = Data(pending[pending.index(after: newline)...])
    }
    while pending.count > Self.limit {
      lines.append(Self.text(pending.prefix(Self.limit)))
      pending = Data(pending.dropFirst(Self.limit))
    }
    return lines
  }

  /// The last line when the script exits without a final newline.
  public mutating func finish() -> [String] {
    defer { pending = Data() }
    return pending.isEmpty ? [] : [Self.text(pending)]
  }

  static func text(_ bytes: Data) -> String {
    var text = String(decoding: bytes, as: UTF8.self)
    if text.hasSuffix("\r") { text.removeLast() }
    return text
  }
}

/// A watcher's `every`: "30s", "2m", "1h", "1d" (a bare number is seconds). At least 10 seconds, so a watcher can't
/// spin.
public enum AutomationInterval {
  public static let minimum: TimeInterval = 10

  /// Seconds, or nil when it isn't an interval (validation says "use 30s, 2m, 1h or 1d").
  public static func parse(_ text: String) -> TimeInterval? {
    let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
    let units: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3600, "d": 86_400]
    let unit = trimmed.last.flatMap { units[$0] }
    let number = unit == nil ? trimmed : String(trimmed.dropLast())
    guard let value = Double(number), value.isFinite, value > 0 else { return nil }
    return value * (unit ?? 1)
  }
}
