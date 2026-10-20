import Foundation

/// Splits the bytes `glance automation mcp` reads from stdin into lines, holding at most `limit` bytes of a line
/// plus the chunk being fed: a line over `limit` is dropped as it arrives (one `.tooLong` for it), and its rest is
/// skipped up to the next line break, so a giant line can't fill the server's memory.
public struct AutomationMCPLines: Sendable {
  public enum Event: Equatable, Sendable {
    case line(String)
    /// A line went over the limit (reported once, when it crossed it).
    case tooLong
  }

  public let limit: Int
  private var pending = Data()
  private var skipping = false

  public init(limit: Int = AutomationMCP.maxLineBytes) { self.limit = limit }

  /// The events a chunk of input completes, in order.
  public mutating func feed(_ chunk: Data) -> [Event] {
    var events: [Event] = []
    var rest = chunk[...]
    while !rest.isEmpty {
      guard let newline = rest.firstIndex(of: UInt8(ascii: "\n")) else {
        if skipping { break }
        if pending.count + rest.count > limit {
          events.append(.tooLong)
          pending = Data()
          skipping = true
        } else {
          pending.append(contentsOf: rest)
        }
        break
      }
      let head = rest[rest.startIndex..<newline]
      rest = rest[(newline + 1)...]
      if skipping {
        skipping = false
      } else if pending.count + head.count > limit {
        events.append(.tooLong)
        pending = Data()
      } else {
        pending.append(contentsOf: head)
        events.append(.line(String(decoding: pending, as: UTF8.self)))
        pending = Data()
      }
    }
    return events
  }

  /// The input ended: a last line with no line break still counts.
  public mutating func finish() -> [Event] {
    defer { pending = Data(); skipping = false }
    guard !skipping, !pending.isEmpty else { return [] }
    return [.line(String(decoding: pending, as: UTF8.self))]
  }
}
