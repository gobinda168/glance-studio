import Foundation

/// One meaningful transcript line: a turn (prompt / done) or a tool call starting or settling.
public enum TranscriptEvent: Equatable, Sendable {
  case turn(TurnEvent)
  case tool(ToolEvent)
}

/// Follows growing transcript files: given a file's new size, it asks for only the appended bytes and turns the
/// complete lines into turn events. Pure (the caller does the reading), so it's tested without a file system.
public struct TranscriptTail {
  private var offsets: [String: UInt64] = [:]
  /// Bytes after the last newline, kept as bytes so a character split across two reads decodes intact.
  private var partial: [String: Data] = [:]
  private var cwds: [String: String] = [:]

  public init() {}

  /// What's in the file so far is history: mark it read.
  public mutating func skip(file: String, size: UInt64) {
    offsets[file] = size
  }

  /// All meaningful events (turns and tool calls) in what was appended to `file` since the last call, now that it's
  /// `size` bytes long. `read` returns the bytes in `from..<to`, or nil when the file can't be read (it's asked
  /// again next time). A file that shrank was rewritten: it's read again from the start. An event without a `cwd`
  /// gets the file's last known one.
  public mutating func allEvents(in file: String, size: UInt64, read: (_ from: UInt64, _ to: UInt64) -> Data?) -> [TranscriptEvent] {
    var from = offsets[file] ?? 0
    if size < from {
      from = 0
      partial[file] = nil
    }
    guard size > from, let data = read(from, size) else { return [] }
    offsets[file] = from + UInt64(data.count)
    let buffer = (partial[file] ?? Data()) + data
    guard let newline = buffer.lastIndex(of: 0x0A) else {
      partial[file] = buffer
      return []
    }
    partial[file] = Data(buffer[buffer.index(after: newline)...])
    var events: [TranscriptEvent] = []
    for line in buffer[..<newline].split(separator: 0x0A) {
      let text = String(decoding: line, as: UTF8.self)
      if let event = Transcript.turnEvent(line: text) {
        if let cwd = event.cwd { cwds[file] = cwd }
        events.append(.turn(TurnEvent(kind: event.kind, cwd: event.cwd ?? cwds[file])))
      }
      for tool in Transcript.toolEvents(line: text) {
        if let cwd = tool.cwd { cwds[file] = cwd }
        events.append(.tool(ToolEvent(kind: tool.kind, cwd: tool.cwd ?? cwds[file])))
      }
    }
    return events
  }

  /// The turn events in what was appended to `file` since the last call, now that it's `size` bytes long.
  /// `read` returns the bytes in `from..<to`, or nil when the file can't be read (it's asked again next time).
  /// A file that shrank was rewritten: it's read again from the start. An event without a `cwd` gets the file's
  /// last known one.
  public mutating func events(in file: String, size: UInt64, read: (_ from: UInt64, _ to: UInt64) -> Data?) -> [TurnEvent] {
    allEvents(in: file, size: size, read: read).compactMap { if case .turn(let turn) = $0 { turn } else { nil } }
  }
}
