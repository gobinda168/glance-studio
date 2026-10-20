import CoreServices
import Foundation
import GlanceCore

/// Follows Claude Code sessions by watching their transcripts (~/.claude/projects/<project>/<session>.jsonl), the Swift
/// counterpart of the VS Code extension's watcher. A prompt means Claude is thinking; a finished turn means the reply
/// is ready. No hooks needed. Files are read on a background queue; events arrive on the main thread.
@MainActor
public final class TranscriptWatcher {
  public struct Event: Equatable, Sendable {
    public let kind: TurnEvent.Kind
    /// The transcript, for `GlanceSession.loadReply(from:)`.
    public let file: String
    public let cwd: String?
  }

  public struct ToolNote: Equatable, Sendable {
    public let file: String
    public let event: ToolEvent
  }

  /// Which sessions count, by working directory. The others are ignored.
  public var accepts: (String?) -> Bool = { _ in true }
  public var onEvent: ((Event) -> Void)?
  public var onTool: ((ToolNote) -> Void)?

  private let root: URL
  private let reader: Reader
  private var stream: FSEventStreamRef?
  private var doneTimers: [String: DispatchWorkItem] = [:]

  public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")) {
    // FSEvents reports real paths; resolve symlinks so they match what `skipExisting` records.
    self.root = root.resolvingSymlinksInPath()
    reader = Reader(root: self.root)
  }

  /// Starts watching. Transcripts already on disk are history: only what's appended from now on counts.
  /// False when FSEvents can't watch the folder.
  @discardableResult
  public func start() -> Bool {
    guard stream == nil else { return true }
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    reader.deliver = { [weak self] events, tools in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(events); self?.handleTools(tools) } }
    }
    reader.queue.sync { reader.skipExisting() }
    var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(reader).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
    let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                                         | kFSEventStreamCreateFlagNoDefer)
    guard let stream = FSEventStreamCreate(nil, { _, info, _, paths, _, _ in
      guard let info else { return }
      let reader = Unmanaged<Reader>.fromOpaque(info).takeUnretainedValue()
      reader.changed(unsafeBitCast(paths, to: NSArray.self) as? [String] ?? [])
    }, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags)
    else { return false }
    FSEventStreamSetDispatchQueue(stream, reader.queue)
    guard FSEventStreamStart(stream) else {
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      return false
    }
    self.stream = stream
    return true
  }

  public func stop() {
    if let stream {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
    }
    stream = nil
    doneTimers.values.forEach { $0.cancel() }
    doneTimers.removeAll()
  }

  private func handleTools(_ tools: [ToolNote]) {
    for note in tools where accepts(note.event.cwd) { onTool?(note) }
  }

  private func handle(_ events: [Event]) {
    for event in events where accepts(event.cwd) {
      doneTimers[event.file]?.cancel()
      switch event.kind {
      case .prompt:
        onEvent?(event)
      case .done:
        // A finished turn writes several entries (text, summaries): wait for the burst to end.
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.onEvent?(event) } }
        doneTimers[event.file] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
      }
    }
  }

  /// Reads appended transcript bytes on its own queue; `tail` is only touched there.
  private final class Reader: @unchecked Sendable {
    let queue = DispatchQueue(label: "dev.glance.transcripts")
    let root: URL
    var tail = TranscriptTail()
    var deliver: (([Event], [ToolNote]) -> Void)?

    init(root: URL) { self.root = root }

    func skipExisting() {
      let files = FileManager.default
      for project in (try? files.contentsOfDirectory(atPath: root.path)) ?? [] {
        let folder = root.appendingPathComponent(project)
        for name in (try? files.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".jsonl") {
          let path = folder.appendingPathComponent(name).path
          tail.skip(file: path, size: Self.size(of: path))
        }
      }
    }

    func changed(_ paths: [String]) {
      var events: [Event] = []
      var tools: [ToolNote] = []
      for path in Set(paths) where path.hasSuffix(".jsonl") {
        let all = tail.allEvents(in: path, size: Self.size(of: path)) { from, to in Self.read(path, from: from, to: to) }
        for item in all {
          switch item {
          case .turn(let turn): events.append(Event(kind: turn.kind, file: path, cwd: turn.cwd))
          case .tool(let tool): tools.append(ToolNote(file: path, event: tool))
          }
        }
      }
      if !events.isEmpty || !tools.isEmpty { deliver?(events, tools) }
    }

    static func size(of path: String) -> UInt64 {
      ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    static func read(_ path: String, from: UInt64, to: UInt64) -> Data? {
      guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
      defer { try? handle.close() }
      do {
        try handle.seek(toOffset: from)
        return try handle.read(upToCount: Int(to - from))
      } catch {
        return nil
      }
    }
  }
}
