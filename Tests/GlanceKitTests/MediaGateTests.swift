import Foundation
import Testing
@testable import GlanceKit

// The gate that thumbnails and video lengths go through: off the cooperative pool, two at a time, each with a time limit.

private final class Probe: @unchecked Sendable {
  private let lock = NSLock()
  private var active = 0
  private(set) var peak = 0
  private(set) var started = 0
  func enter() { lock.lock(); active += 1; started += 1; peak = max(peak, active); lock.unlock() }
  func leave() { lock.lock(); active -= 1; lock.unlock() }
}

@Suite struct MediaGateTests {
  @Test func atMostTwoRunAtOnceAndEveryRequestReturnsItsValue() async {
    let gate = MediaGate(width: 2, limit: 30, maxAbandoned: 4)
    let probe = Probe()
    let values = await withTaskGroup(of: Int?.self, returning: [Int?].self) { group in
      for i in 0..<30 {
        group.addTask {
          await gate.run { () -> Int? in
            probe.enter(); defer { probe.leave() }
            Thread.sleep(forTimeInterval: 0.01)
            return i
          }
        }
      }
      var out: [Int?] = []
      for await value in group { out.append(value) }
      return out
    }
    #expect(values.compactMap { $0 }.sorted() == Array(0..<30))
    #expect(probe.peak <= 2 && probe.peak >= 1)
  }

  @Test func requestsOnAStuckGeneratorAllReturnWithinTheLimit() async {
    let release = DispatchSemaphore(value: 0)
    // The stuck ones block a thread for good (until the test ends); they must not hold up the rest.
    defer { for _ in 0..<12 { release.signal() } }
    let gate = MediaGate(width: 2, limit: 1.0, maxAbandoned: 6)
    let started = Date()
    let values = await withTaskGroup(of: Int?.self, returning: [Int?].self) { group in
      for i in 0..<20 {
        group.addTask {
          await gate.run { () -> Int? in
            if i % 10 == 0 { release.wait(); return nil } // 2 of the 20 never come back
            return i
          }
        }
      }
      var out: [Int?] = []
      for await value in group { out.append(value) }
      return out
    }
    #expect(values.count == 20, "every request returned")
    #expect(Date().timeIntervalSince(started) < 30)
    #expect(values.compactMap { $0 }.count == 18, "the ones that could finish did")
  }

  @Test func whenTooManyAreStuckNewRequestsAnswerNothingAtOnce() async {
    let release = DispatchSemaphore(value: 0)
    defer { for _ in 0..<12 { release.signal() } }
    let gate = MediaGate(width: 2, limit: 0.1, maxAbandoned: 2)
    for _ in 0..<2 { _ = await gate.run { () -> Int? in release.wait(); return nil } } // both time out, both threads stay stuck
    let started = Date()
    let value = await gate.run { () -> Int? in 7 }
    #expect(value == nil, "no thread is risked on a pool that has swallowed its limit")
    #expect(Date().timeIntervalSince(started) < 5)
  }

  @Test func aSlotIsFreedAgainWhenAStuckOneComesBack() async {
    let release = DispatchSemaphore(value: 0)
    let gate = MediaGate(width: 2, limit: 0.1, maxAbandoned: 1)
    _ = await gate.run { () -> Int? in release.wait(); return nil }
    release.signal() // it comes back late
    try? await Task.sleep(nanoseconds: 300_000_000)
    let value = await gate.run { () -> Int? in 5 }
    #expect(value == 5)
  }

  // A finished request must leave nothing behind: the job's own closures once held the job (a retain cycle), so every
  // request leaked its job and the work it captured.
  private final class Sentinel: @unchecked Sendable {}

  @Test func aFinishedJobIsReleased() async {
    // A roomy limit for the request that finishes (a loaded machine must not time it out), a short one for the stuck.
    let gate = MediaGate(width: 2, limit: 3, maxAbandoned: 4)
    let shortGate = MediaGate(width: 2, limit: 0.2, maxAbandoned: 4)
    weak var finished: Sentinel?
    weak var timedOut: Sentinel?
    do {
      let a = Sentinel(), b = Sentinel()
      finished = a
      timedOut = b
      let value = await gate.run { () -> Int? in _ = a; return 1 }
      #expect(value == 1)
      let release = DispatchSemaphore(value: 0)
      defer { release.signal() }
      let none = await shortGate.run { () -> Int? in _ = b; release.wait(); return nil } // outlives the limit
      #expect(none == nil)
    }
    // The gate's own timer holds the job until the limit passes; after that nothing should.
    for _ in 0..<100 where finished != nil { try? await Task.sleep(nanoseconds: 100_000_000) }
    #expect(finished == nil, "the work of a finished request is released")
    for _ in 0..<100 where timedOut != nil { try? await Task.sleep(nanoseconds: 100_000_000) }
    #expect(timedOut == nil, "so is the work of one that timed out, once it returns")
  }
}
