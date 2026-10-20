import Foundation
import GlanceCore

/// Follows the one transcript the chat shows and hands its thread to `onThread` (main thread) each time the file grows.
/// Only the last 2 MB is read (long sessions are many MB), on a background queue, at most every 150 ms.
@MainActor
public final class ChatFeed {
  nonisolated public static let defaultProjects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")

  public var onThread: ((ChatThread) -> Void)?
  public private(set) var file: String?
  private var root: String?
  private var source: DispatchSourceFileSystemObject?
  private let queue = DispatchQueue(label: "dev.glance.chat-feed")
  private var generation = 0
  private var reading = false
  private var again = false

  public init() {}

  /// Shows `file`'s conversation (paths relative to `root`); nil shows an empty one.
  public func follow(_ file: String?, root: String?) {
    guard file != self.file || root != self.root else { return }
    unwatch()
    self.file = file
    self.root = root
    generation += 1
    reading = false
    again = false
    guard let file else { onThread?(ChatThread()); return }
    watch(file)
    reload()
  }

  private func watch(_ file: String) {
    let descriptor = open(file, O_EVTONLY)
    guard descriptor >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                           eventMask: [.write, .extend, .delete, .rename], queue: .main)
    source.setEventHandler { [weak self, weak source] in
      MainActor.assumeIsolated {
        guard let self, let events = source?.data else { return }
        // Rewritten in place (deleted or renamed, then written again): watch the new file.
        if events.contains(.delete) || events.contains(.rename), let file = self.file {
          self.unwatch()
          self.watch(file)
        }
        self.reload()
      }
    }
    source.setCancelHandler { close(descriptor) }
    source.resume()
    self.source = source
  }

  private func unwatch() {
    source?.cancel()
    source = nil
  }

  private func reload() {
    guard let file else { return }
    guard !reading else { again = true; return }
    reading = true
    let mine = generation, root = root
    queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
      let (text, truncated) = Self.tail(file)
      let thread = ChatTranscript.thread(jsonl: text, root: root, truncated: truncated)
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self, mine == self.generation else { return }
          self.reading = false
          self.onThread?(thread)
          if self.again { self.again = false; self.reload() }
        }
      }
    }
  }

  /// The file's last `window` bytes, and whether that cut anything off (the cut first line then fails to parse and is
  /// skipped by `ChatTranscript`).
  nonisolated static func tail(_ path: String, window: UInt64 = 2 << 20) -> (String, Bool) {
    guard let handle = FileHandle(forReadingAtPath: path) else { return ("", false) }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    try? handle.seek(toOffset: size > window ? size - window : 0)
    let data = (try? handle.readToEnd()) ?? Data()
    return (String(decoding: data, as: UTF8.self), size > window)
  }

  /// The file's first 128 KB: enough for a session's first prompt.
  nonisolated static func head(_ path: String, window: Int = 128 << 10) -> String {
    guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
    defer { try? handle.close() }
    return String(decoding: (try? handle.read(upToCount: window)) ?? Data(), as: UTF8.self)
  }

  /// `<projects>/*/<id>.jsonl`: Claude Code may spell the project folder differently (symlinks, /private).
  nonisolated public static func locate(id: String, projects: URL = defaultProjects) -> String? {
    let files = FileManager.default
    for folder in (try? files.contentsOfDirectory(atPath: projects.path)) ?? [] {
      let path = projects.appendingPathComponent(folder).appendingPathComponent(id + ".jsonl").path
      if files.fileExists(atPath: path) { return path }
    }
    return nil
  }
}
