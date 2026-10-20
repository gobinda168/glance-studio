import Foundation

/// Tells the session when Claude Code's plan usage changes: it watches the status-line script's `usage.json` and re-reads
/// once a minute, so a window that has reset disappears, and the "updated 4m ago" text moves on, without a new write.
/// Everything runs on `queue`, which is also where `onChange` is called.
public final class UsageWatcher: @unchecked Sendable {
  public typealias Reading = UsageTracker.Reading

  /// Nil: nothing to show (no file, unreadable, or every window has reset).
  public var onChange: (@Sendable (Reading?) -> Void)?

  private let file: URL
  private let queue: DispatchQueue
  private let tick: TimeInterval
  private let retry: TimeInterval
  private var source: DispatchSourceFileSystemObject?
  private var timer: DispatchSourceTimer?
  private var tracker = UsageTracker()
  private var stopped = false

  /// `tick`: how often the file is re-read anyway. `retry`: how often a directory that isn't there is looked for.
  public init(
    file: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/glance/usage.json"),
    queue: DispatchQueue = .main, tick: TimeInterval = 60, retry: TimeInterval = 5
  ) {
    self.file = file
    self.queue = queue
    self.tick = tick
    self.retry = retry
  }

  public func start() {
    queue.async { [self] in
      stopped = false
      if !watchDirectory() { scheduleRewatch() }
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now() + tick, repeating: tick)
      timer.setEventHandler { [weak self] in self?.reload() }
      timer.resume()
      self.timer = timer
      reload()
    }
  }

  public func stop() {
    queue.async { [self] in
      stopped = true
      timer?.cancel()
      timer = nil
      source?.cancel()
      source = nil
    }
  }

  deinit {
    timer?.cancel()
    source?.cancel()
  }

  /// The directory, not the file: the script replaces the file with `mv`, which a watch on the old file would miss.
  private func watchDirectory() -> Bool {
    let descriptor = open(file.deletingLastPathComponent().path, O_EVTONLY)
    guard descriptor >= 0 else { return false }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: queue)
    source.setEventHandler { [weak self, weak source] in
      guard let self, let source else { return }
      // The directory itself went (`unsetup` then `setup` recreates it): this watch is dead, look for the new one.
      if !source.data.isDisjoint(with: [.delete, .rename]) {
        source.cancel()
        self.source = nil
        scheduleRewatch()
      }
      reload()
    }
    source.setCancelHandler { close(descriptor) }
    source.resume()
    self.source = source
    return true
  }

  /// Looks for the directory again until it exists (`~/.claude/glance` only appears after `Glance setup`).
  private func scheduleRewatch() {
    queue.asyncAfter(deadline: .now() + retry) { [weak self] in
      guard let self, !stopped, source == nil else { return }
      if watchDirectory() { reload() } else { scheduleRewatch() }
    }
  }

  private func reload() {
    let now = Date()
    onChange?(tracker.update(PlanUsage.load(from: file, now: now), now: now))
  }
}
