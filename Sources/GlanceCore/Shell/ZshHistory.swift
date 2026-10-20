import Foundation

/// zsh's history file (`$HISTFILE`, `~/.zsh_history`), for the one-time import (spec "S2: history", "Import"): read
/// the way zsh reads it (hist.c): metafied bytes decoded, a line ending in a backslash joined to the next with a
/// newline, and `: <start>:<elapsed>;<command>` when EXTENDED_HISTORY wrote it.
public enum ZshHistory {
  public struct Entry: Equatable, Sendable {
    public let command: String
    public let start: Date?
    public let duration: TimeInterval?
  }

  public static func parse(_ data: Data) -> [Entry] {
    var entries: [Entry] = []
    var current: [UInt8] = []
    var continuing = false
    for line in unmetafied(data).split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
      var bytes = Array(line)
      if continuing { current.append(UInt8(ascii: "\n")) } else { current.removeAll(keepingCapacity: true) }
      if bytes.last == UInt8(ascii: "\\") {
        bytes.removeLast()
        current += bytes
        continuing = true
        continue
      }
      current += bytes
      continuing = false
      if let entry = entry(String(decoding: current, as: UTF8.self)) { entries.append(entry) }
    }
    if continuing, let entry = entry(String(decoding: current, as: UTF8.self)) { entries.append(entry) }
    return entries
  }

  /// zsh writes some bytes as Meta (0x83) followed by the byte XOR 0x20.
  static func unmetafied(_ data: Data) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(data.count)
    var meta = false
    for byte in data {
      if meta {
        out.append(byte ^ 0x20)
        meta = false
      } else if byte == 0x83 {
        meta = true
      } else {
        out.append(byte)
      }
    }
    return out
  }

  private static func entry(_ text: String) -> Entry? {
    if text.hasPrefix(": "), let semicolon = text.firstIndex(of: ";") {
      let stamp = text[text.index(text.startIndex, offsetBy: 2)..<semicolon].split(separator: ":")
      if stamp.count == 2, let start = Double(stamp[0]), let elapsed = Double(stamp[1]) {
        let command = String(text[text.index(after: semicolon)...])
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Entry(command: command, start: Date(timeIntervalSince1970: start), duration: elapsed)
      }
    }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return Entry(command: text, start: nil, duration: nil)
  }
}

extension ZshHistory {
  /// The history rows an import makes (spec "S2: history", "Import"): no folder or exit code, the file's own times when
  /// it has them, else spaced a second apart in the file's order and ending at `before` (the first recorded run), so
  /// the newest line of the file sorts newest. What `HistoryPolicy` keeps out stays out.
  public static func records(_ entries: [Entry], before: Date) -> [CommandRecord] {
    let count = entries.count
    return entries.enumerated().compactMap { offset, entry in
      guard HistoryPolicy.shouldRecord(entry.command) else { return nil }
      let start = entry.start ?? before.addingTimeInterval(-Double(count - offset))
      return CommandRecord(command: entry.command, folder: nil, start: start, duration: entry.duration, exitCode: nil,
                           tab: nil, gitRoot: nil, branch: nil, imported: true)
    }
  }
}
