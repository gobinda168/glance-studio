import Foundation

/// Reads what's new in Claude Code's transcripts into the usage store (spec "Import"). Each project folder's
/// `<session>.jsonl` and `<session>/subagents/*.jsonl` are read from their mark: from the start when the file is new,
/// replaced (another inode) or shorter than its mark, else from the mark. Only complete lines are read, so a line still
/// being written waits for the next scan. Blocks until done: callers run it off the main thread.
public enum UsageScanner {
  public struct Progress: Equatable, Sendable {
    public var done: Int
    public var total: Int

    public init(done: Int, total: Int) {
      self.done = done
      self.total = total
    }
  }

  static let chunk = 1 << 20

  /// Every transcript under `projects`.
  public static func transcripts(in projects: URL) -> [URL] {
    let files = FileManager.default
    let folders = (try? files.contentsOfDirectory(at: projects, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    var found: [URL] = []
    for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
      let entries = (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
      for entry in entries {
        if entry.pathExtension == "jsonl" {
          found.append(entry)
        } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
          let subagents = entry.appendingPathComponent("subagents")
          let agents = (try? files.contentsOfDirectory(at: subagents, includingPropertiesForKeys: nil)) ?? []
          found += agents.filter { $0.pathExtension == "jsonl" }
        }
      }
    }
    return found.sorted { $0.path < $1.path }
  }

  /// Reads every transcript's new lines into `store`, and forgets the marks of transcripts that are gone. Returns how
  /// many records were read.
  @discardableResult
  public static func scan(projects: URL, store: UsageStore, root: (String) -> String,
                          temporary: String = NSTemporaryDirectory(),
                          progress: (Progress) -> Void = { _ in }) throws -> Int {
    let urls = transcripts(in: projects)
    let marks = try store.marks()
    var read = 0
    for (index, url) in urls.enumerated() {
      defer { progress(Progress(done: index + 1, total: urls.count)) }
      let path = url.path
      guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { continue }
      let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
      let inode = (attributes[.systemFileNumber] as? NSNumber)?.intValue ?? 0
      let mark = marks[path]
      if let mark, mark.inode == inode, mark.size == size { continue }
      let start = mark.map { $0.inode == inode && size >= $0.offset ? $0.offset : 0 } ?? 0
      var records: [UsageRecord] = []
      guard let end = readLines(url, from: start, line: { text, offset in
        if let record = UsageImport.record(line: text, file: path, offset: offset, root: root, temporary: temporary) {
          records.append(record)
        }
      }) else { continue }
      try store.save(records, path: path, mark: UsageStore.FileMark(offset: end, inode: inode, size: size))
      read += records.count
    }
    try store.keepMarks(only: Set(urls.map(\.path)))
    return read
  }

  /// Calls `line` with each complete line of `url` from `offset` and the line's own offset, reading a megabyte at a
  /// time; returns the offset just past the last newline, or nil when the file can't be opened.
  static func readLines(_ url: URL, from offset: Int, line: (String, Int) -> Void) -> Int? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { return nil }
    var buffer = Data()
    var bufferStart = offset
    while let data = try? handle.read(upToCount: chunk), !data.isEmpty {
      buffer.append(data)
      var lineStart = 0
      while let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
        line(String(decoding: buffer[lineStart..<newline], as: UTF8.self), bufferStart + lineStart)
        lineStart = newline + 1
      }
      if lineStart > 0 {
        buffer = Data(buffer[lineStart...])
        bufferStart += lineStart
      }
    }
    return bufferStart
  }
}
