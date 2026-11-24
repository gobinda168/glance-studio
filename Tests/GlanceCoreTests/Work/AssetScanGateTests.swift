import Foundation
import Testing
@testable import GlanceCore

@Suite struct AssetScanGateTests {
  let t0 = Date(timeIntervalSince1970: 1_000)
  func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

  /// A gate whose setup is read. (A class, so that `#expect` can call its mutating methods.)
  final class Gate {
    var gate = AssetScanGate(interval: 20)
    func request(now: Date) -> AssetScanGate.Decision { gate.request(now: now) }
    func trailingFired(now: Date) -> AssetScanGate.Decision { gate.trailingFired(now: now) }
    func finished(now: Date) -> Bool { gate.finished(now: now) }
    func setup(loaded: Bool, patterns: [String]) -> Bool { gate.setup(loaded: loaded, patterns: patterns) }
    func reset() { gate.reset() }
    var currentPatterns: [String] { gate.currentPatterns }
  }

  func ready(patterns: [String] = []) -> Gate {
    let gate = Gate()
    _ = gate.setup(loaded: true, patterns: patterns)
    return gate
  }

  @Test func nothingStartsBeforeTheSetupIsRead() {
    let gate = Gate()
    #expect(gate.request(now: at(0)) == .none)
    // Reading it is the cue to ask: the waiting request is not lost.
    #expect(gate.setup(loaded: true, patterns: ["docs/**"]))
    #expect(gate.request(now: at(1)) == .start)
    #expect(gate.currentPatterns == ["docs/**"])
  }

  @Test func aRequestInsideTheWindowKeepsOneTrailingScan() {
    let gate = ready()
    #expect(gate.request(now: at(0)) == .start)
    _ = gate.finished(now: at(2))
    #expect(gate.request(now: at(5)) == .wait(until: at(20)))
    // Several more before the window ends join it: no second plan.
    #expect(gate.request(now: at(8)) == .none)
    #expect(gate.request(now: at(15)) == .none)
    #expect(gate.trailingFired(now: at(20)) == .start)
  }

  @Test func theTrailingScanRunsOnceWhateverWasAskedMeanwhile() {
    let gate = ready()
    _ = gate.request(now: at(0))
    _ = gate.finished(now: at(1))
    for second in stride(from: 2.0, to: 19.0, by: 3) { _ = gate.request(now: at(second)) }
    #expect(gate.trailingFired(now: at(20)) == .start)
    #expect(gate.finished(now: at(22)) == false, "the trailing scan answered every request that came before it")
  }

  @Test func aRequestAfterTheWindowStartsAtOnce() {
    let gate = ready()
    #expect(gate.request(now: at(0)) == .start)
    _ = gate.finished(now: at(1))
    #expect(gate.request(now: at(21)) == .start)
  }

  @Test func scansNeverOverlapAndOneMoreFollowsARequestMadeWhileRunning() {
    let gate = ready()
    #expect(gate.request(now: at(0)) == .start)
    #expect(gate.request(now: at(3)) == .none)
    #expect(gate.request(now: at(4)) == .none)
    #expect(gate.finished(now: at(30)), "one more is owed")
    #expect(gate.request(now: at(30)) == .start, "and it is not made to wait out the window")
    #expect(gate.finished(now: at(31)) == false)
  }

  @Test func aSetupChangeAfterAScanAsksForAnother() {
    let gate = ready(patterns: [])
    #expect(gate.request(now: at(0)) == .start)
    #expect(gate.setup(loaded: true, patterns: ["docs/**"]), "new patterns need a rescan")
    _ = gate.finished(now: at(1))
    #expect(gate.request(now: at(2)) == .wait(until: at(20)))
  }

  @Test func theSameSetupAgainAsksForNothing() {
    let gate = ready(patterns: ["a/**"])
    _ = gate.request(now: at(0))
    #expect(gate.setup(loaded: true, patterns: ["a/**"]) == false)
  }

  @Test func aFolderChangeVoidsThePlan() {
    let gate = ready()
    _ = gate.request(now: at(0))
    _ = gate.request(now: at(1))   // owed
    gate.reset()
    #expect(gate.setup(loaded: false, patterns: []) == false)
    #expect(gate.request(now: at(2)) == .none, "the new folder's setup is not read yet")
    #expect(gate.setup(loaded: true, patterns: []))
    #expect(gate.request(now: at(3)) == .start, "the old window does not hold the new folder back")
  }
}
