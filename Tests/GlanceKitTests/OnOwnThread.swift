import Foundation

/// Runs blocking work on a thread of its own and hands back the result. An async test must read a video this way:
/// `copyNextSampleBuffer` blocks until CoreMedia's own queues deliver, and the system stops serving those queues once a
/// CPU's worth of cooperative threads are blocked. Enough tests reading on cooperative threads at once then wait on each
/// other for ever.
func onOwnThread<T>(_ read: @escaping () throws -> T) async throws -> T {
  try await withCheckedThrowingContinuation { continuation in
    DispatchQueue(label: "dev.glance.tests.read").async {
      continuation.resume(with: Result { try read() })
    }
  }
}

/// A gate a stuck step waits at. Opens by itself after `seconds`, so code that wrongly waits for it can't wedge the run.
final class SelfOpeningGate: @unchecked Sendable {
  private let condition = NSCondition()
  private var isOpen = false

  init(opensAfter seconds: Double) {
    DispatchQueue(label: "dev.glance.tests.gate").asyncAfter(deadline: .now() + seconds) { [self] in open() }
  }

  func open() {
    condition.lock()
    isOpen = true
    condition.broadcast()
    condition.unlock()
  }

  func wait() {
    condition.lock()
    while !isOpen { condition.wait() }
    condition.unlock()
  }
}

/// Comes back when `semaphore` is signalled, without blocking a cooperative thread. False if it wasn't within 20 s.
func reached(_ semaphore: DispatchSemaphore) async throws -> Bool {
  try await onOwnThread { semaphore.wait(timeout: .now() + 20) == .success }
}
