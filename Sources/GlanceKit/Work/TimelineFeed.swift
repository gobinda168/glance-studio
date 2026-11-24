import Foundation
import GlanceCore

/// Follows one transcript file for the Glance view: reads what's appended, parses it on a background queue and hands
/// the main thread a finished SessionTimeline at most every 100 ms. Starts from the last 16 MB of very large files.
@MainActor
public final class TimelineFeed {
  public var onChange: ((SessionTimeline) -> Void)?
  public private(set) var path: String?
  nonisolated public static let initialLimit: UInt64 = 16 << 20

  private var reader: Reader?
  /// Bumped by every follow/stop so a finished snapshot from an earlier reader (even for the same path) is dropped.
  private var generation = 0

  /// How much of a large file is read at the start; the board follows many sessions, so it asks for less.
  private let limit: UInt64

  public init(initialLimit: UInt64 = TimelineFeed.initialLimit) { limit = initialLimit }

  /// Follows `path` (rows' paths relative to `root`) from scratch; nil stops. The same path again does nothing.
  public func follow(_ path: String?, root: String?) {
    guard path != self.path else { return }
    stop()
    self.path = path
    guard let path else { return }
    let mine = generation
    let reader = Reader(path: path, root: root, limit: limit) { [weak self] timeline in
      Task { @MainActor in
        guard let self, self.generation == mine, self.path == path else { return }
        self.onChange?(timeline)
      }
    }
    self.reader = reader
    reader.start()
  }

  public func stop() {
    reader?.cancel()
    reader = nil
    path = nil
    generation += 1
  }

  /// Owns the file handle, the builder and the watch; touched only on its queue.
  private final class Reader: @unchecked Sendable {
    private let path: String, root: String?, limit: UInt64
    private let deliver: @Sendable (SessionTimeline) -> Void
    private let queue = DispatchQueue(label: "dev.glance.timeline-feed", qos: .userInitiated)
    private var timeline: SessionTimeline
    private var chunker = LineChunker()
    private var offset: UInt64 = 0
    private var skipToNextLine = false
    private var source: DispatchSourceFileSystemObject?
    private var scheduled = false
    private var cancelled = false

    init(path: String, root: String?, limit: UInt64, deliver: @escaping @Sendable (SessionTimeline) -> Void) {
      self.path = path; self.root = root; self.limit = limit; self.deliver = deliver
      timeline = SessionTimeline(root: root)
    }

    func start() {
      queue.async {
        let size = Self.size(self.path)
        if size > self.limit {
          self.offset = size - self.limit
          self.timeline.truncated = true
          self.skipToNextLine = true
        }
        self.watch()                             // before the read, so nothing appended during it is missed
        self.read()
      }
    }

    func cancel() {
      queue.async {
        self.cancelled = true
        self.source?.cancel()
        self.source = nil
      }
    }

    private func watch() {
      guard !cancelled else { return }
      let fd = open(path, O_EVTONLY)
      guard fd >= 0 else {                       // not there (yet): try again shortly
        queue.asyncAfter(deadline: .now() + 0.5) { self.watch(); self.read() }
        return
      }
      let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: queue)
      source.setEventHandler { [weak self, weak source] in
        guard let self, let events = source?.data else { return }
        if events.contains(.delete) || events.contains(.rename) {
          source?.cancel()
          self.source = nil
          self.queue.asyncAfter(deadline: .now() + 0.5) { self.watch(); self.read() }
          return
        }
        self.schedule()
      }
      source.setCancelHandler { close(fd) }
      self.source = source
      source.resume()
    }

    private func schedule() {
      guard !scheduled else { return }
      scheduled = true
      queue.asyncAfter(deadline: .now() + 0.1) { self.scheduled = false; self.read() }
    }

    private func read() {
      guard !cancelled, let handle = FileHandle(forReadingAtPath: path) else { return }
      defer { try? handle.close() }
      let size = Self.size(path)
      var rewritten = false
      if size < offset {                         // rewritten from the start
        offset = 0; skipToNextLine = false; chunker.reset(); timeline = SessionTimeline(root: root)
        rewritten = true
      }
      guard size > offset else {
        if rewritten { deliver(timeline) }
        return
      }
      try? handle.seek(toOffset: offset)
      guard var data = try? handle.read(upToCount: Int(size - offset)), !data.isEmpty else { return }
      offset += UInt64(data.count)
      if skipToNextLine {                        // the cut-off first line of a truncated read
        guard let nl = data.firstIndex(of: 0x0A) else { return }
        data = Data(data[data.index(after: nl)...])
        skipToNextLine = false
      }
      timeline.ingest(lines: chunker.feed(data))
      deliver(timeline)
    }

    private static func size(_ path: String) -> UInt64 {
      ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }
  }
}
