import Foundation

/// Where blocking media reads (a video's first frame, its length) run: on threads of their own, never on Swift's
/// cooperative pool. Once a CPU's worth of cooperative threads are blocked the system stops serving CoreMedia's read and
/// close work, and a thread that waits for it can't be freed (see av-hang-report.md), so a grid asking for many frames at
/// once must not wait on the pool, and must not wait for ever.
///
/// - At most `width` run at once; the rest wait their turn.
/// - Each has `limit` seconds from the moment it starts. After that its caller gets nil (the tile shows its
///   placeholder) and the slot is given to the next one. The thread of a read that never comes back stays stuck; it
///   counts as abandoned until it does.
/// - With `maxAbandoned` threads stuck, nothing new is started: waiting and new requests answer nil at once rather
///   than add another thread to a pool that is not answering.
final class MediaGate: @unchecked Sendable {
  static let shared = MediaGate()

  private final class Job: @unchecked Sendable {
    /// Take the job as an argument, never capture it: a closure stored on the job that held the job was a retain cycle
    /// and leaked one job (and the work it captured) per request.
    var begin: (Job) -> Void = { _ in }
    var giveUp: (Job) -> Void = { _ in }
    private let lock = NSLock()
    private var settled = false
    /// Both guarded by the gate's lock: the work has returned; the time ran out first.
    var workDone = false
    var abandoned = false
    /// True for the first caller only: the one that gets to answer.
    func settle() -> Bool { lock.lock(); defer { lock.unlock() }; if settled { return false }; settled = true; return true }
  }

  private let width: Int
  private let limit: TimeInterval
  private let maxAbandoned: Int
  private let lock = NSLock()
  private var pending: [Job] = []
  private var running = 0
  private var abandoned = 0
  private let workers = DispatchQueue(label: "dev.glance.media.work", attributes: .concurrent)
  private let timers = DispatchQueue(label: "dev.glance.media.timers")

  init(width: Int = 2, limit: TimeInterval = 10, maxAbandoned: Int = 4) {
    self.width = max(1, width)
    self.limit = limit
    self.maxAbandoned = max(1, maxAbandoned)
  }

  /// `work` on a thread of the gate's, or nil when it takes longer than the limit or the gate has too many stuck.
  func run<T>(_ work: @escaping @Sendable () -> T?) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
      let job = Job()
      job.begin = { [self] job in
        workers.async {
          let value = work()
          if job.settle() { continuation.resume(returning: value) }
          self.ended(job)
        }
        timers.asyncAfter(deadline: .now() + limit) {
          if self.timedOut(job), job.settle() { continuation.resume(returning: nil) }
        }
      }
      job.giveUp = { job in if job.settle() { continuation.resume(returning: nil) } }
      lock.lock()
      pending.append(job)
      dispatch()
    }
  }

  private func ended(_ job: Job) {
    lock.lock()
    job.workDone = true
    if job.abandoned { abandoned -= 1 } else { running -= 1 }
    dispatch()
  }

  /// The slot is given up, unless the work has already come back. True when the caller is to be answered nil.
  private func timedOut(_ job: Job) -> Bool {
    lock.lock()
    guard !job.workDone else { lock.unlock(); return false }
    job.abandoned = true
    running -= 1
    abandoned += 1
    dispatch()
    return true
  }

  /// Called with the lock held; releases it. Starts what there is room for, or answers nil to everything waiting when
  /// too many threads are stuck.
  private func dispatch() {
    var start: [Job] = [], drop: [Job] = []
    if abandoned >= maxAbandoned {
      drop = pending
      pending = []
    } else {
      while running < width, !pending.isEmpty {
        start.append(pending.removeFirst())
        running += 1
      }
    }
    lock.unlock()
    drop.forEach { $0.giveUp($0) }
    start.forEach { $0.begin($0) }
  }
}
