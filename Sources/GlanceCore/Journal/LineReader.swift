import Foundation

/// A text file's lines, read 64 KB at a time: Claude Code transcripts run to tens of megabytes. A missing file has no
/// lines.
public struct LineReader: Sequence {
  public let url: URL

  public init(url: URL) {
    self.url = url
  }

  public func makeIterator() -> Iterator {
    Iterator(handle: try? FileHandle(forReadingFrom: url))
  }

  public final class Iterator: IteratorProtocol {
    private let handle: FileHandle?
    private var buffer = Data()
    /// Where the next line starts in `buffer`.
    private var offset = 0
    private var done = false

    init(handle: FileHandle?) {
      self.handle = handle
      done = handle == nil
    }

    public func next() -> String? {
      while true {
        if let newline = buffer[offset...].firstIndex(of: 0x0A) {
          let line = String(decoding: buffer[offset..<newline], as: UTF8.self)
          offset = newline + 1
          return line
        }
        if done {
          guard offset < buffer.count else { return nil }
          let line = String(decoding: buffer[offset...], as: UTF8.self)
          offset = buffer.count
          return line
        }
        buffer.removeSubrange(0..<offset)
        offset = 0
        if let chunk = try? handle?.read(upToCount: 65_536), !chunk.isEmpty {
          buffer.append(chunk)
        } else {
          done = true
          try? handle?.close()
        }
      }
    }
  }
}
