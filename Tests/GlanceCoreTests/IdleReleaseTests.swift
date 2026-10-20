import Foundation
import Testing
@testable import GlanceCore

@MainActor
private final class Counter {
  var releases = 0
}

@MainActor @Test func releasesOnceIdleForTheWait() async throws {
  let counter = Counter()
  let idle = IdleRelease(after: .milliseconds(50)) { counter.releases += 1 }
  idle.begin()
  idle.end()
  #expect(counter.releases == 0)
  try await Task.sleep(for: .milliseconds(300))
  #expect(counter.releases == 1)
}

@MainActor @Test func neverReleasesWhileInUse() async throws {
  let counter = Counter()
  let idle = IdleRelease(after: .milliseconds(50)) { counter.releases += 1 }
  idle.begin()
  idle.begin()
  idle.end()
  try await Task.sleep(for: .milliseconds(300))
  #expect(counter.releases == 0)
  idle.end()
  try await Task.sleep(for: .milliseconds(300))
  #expect(counter.releases == 1)
}

@MainActor @Test func aNewUseCancelsThePendingRelease() async throws {
  let counter = Counter()
  let idle = IdleRelease(after: .milliseconds(150)) { counter.releases += 1 }
  idle.begin()
  idle.end()
  try await Task.sleep(for: .milliseconds(50))
  idle.begin()
  try await Task.sleep(for: .milliseconds(400))
  #expect(counter.releases == 0)
}

@MainActor @Test func anUnmatchedEndDoesNotRelease() async throws {
  let counter = Counter()
  let idle = IdleRelease(after: .milliseconds(50)) { counter.releases += 1 }
  idle.end()
  try await Task.sleep(for: .milliseconds(300))
  #expect(counter.releases == 0)
}
