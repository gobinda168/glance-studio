import Foundation

/// Appended transcript bytes → complete lines; a partial last line waits for the next write.
public struct LineChunker: Sendable {
  private var partial = Data()
  public init() {}

  public mutating func feed(_ data: Data) -> [String] {
    partial.append(data)
    var lines: [String] = []
    var start = partial.startIndex
    while let newline = partial[start...].firstIndex(of: 0x0A) {
      let line = partial[start..<newline]
      if !line.isEmpty, let text = String(data: line, encoding: .utf8) { lines.append(text) }
      start = partial.index(after: newline)
    }
    partial = Data(partial[start...])
    return lines
  }

  public mutating func reset() { partial.removeAll() }
}
