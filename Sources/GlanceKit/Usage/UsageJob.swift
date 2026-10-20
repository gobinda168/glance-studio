import Foundation
import GlanceCore

/// Token usage's scanning, without the page: it opens `usage.sqlite`, scans Claude Code's transcripts when started and
/// every 2 minutes, and on `scan()`, one scan at a time. The helper process runs it (`glance helper`), so a bad
/// transcript or a long first import can't take Glance Studio with it; Studio reads the same file.
public final class UsageJob: @unchecked Sendable {
  public static let interval: TimeInterval = 120

  private let queue = DispatchQueue(label: "dev.glance.usage.job", qos: .utility)
  private let scanning = DispatchQueue(label: "dev.glance.usage.job.scan", qos: .utility)
  private let emit: @Sendable (HelperWire.Event) -> Void
  private var store: UsageStore?
  private var timer: DispatchSourceTimer?
  private var busy = false
  private var again = false

  public init(emit: @escaping @Sendable (HelperWire.Event) -> Void) {
    self.emit = emit
  }

  public func start() {
    queue.async { [self] in
      if store == nil { store = (try? UsageStore.open(url: UsageService.file))?.store }
      guard store != nil, timer == nil else { return }
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .seconds(10))
      timer.setEventHandler { [weak self] in self?.scanNow() }
      timer.resume()
      self.timer = timer
      scanNow()
    }
  }

  public func stop() {
    queue.async { [self] in
      timer?.cancel()
      timer = nil
    }
  }

  public func scan() {
    queue.async { [self] in
      guard timer != nil else { return }
      scanNow()
    }
  }

  /// On `queue`. A request during a scan runs one more after it.
  private func scanNow() {
    guard let store else { return }
    if busy {
      again = true
      return
    }
    busy = true
    let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    let emit = self.emit
    scanning.async { [self] in
      let first = ((try? store.earliest()) ?? nil) == nil
      var roots: [String: String] = [:]
      let read = (try? UsageScanner.scan(projects: projects, store: store, root: { folder in
        if let known = roots[folder] { return known }
        let found = ProjectRoot.find(from: folder)
        roots[folder] = found
        return found
      }, progress: { progress in
        if first { emit(.usageProgress(done: progress.done, total: progress.total)) }
      })) ?? 0
      queue.async { [self] in
        busy = false
        emit(.usageScanned(read: read))
        if again {
          again = false
          scanNow()
        }
      }
    }
  }
}
