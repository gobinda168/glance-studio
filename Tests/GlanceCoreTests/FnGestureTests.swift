import Testing
@testable import GlanceCore

@Suite struct FnGestureTests {
  @Test func holdBecomesDictationAfterThreshold() {
    var g = FnGesture()
    #expect(g.fnDown(at: 10) == .arm)
    #expect(g.tick(at: 10.1) == nil)
    #expect(g.tick(at: 10.25) == .start)
    #expect(g.isActive)
    #expect(g.fnUp(at: 12) == .commit)
    #expect(!g.isActive)
  }

  @Test func shortTapCancels() {
    var g = FnGesture()
    #expect(g.fnDown(at: 0) == .arm)
    #expect(g.fnUp(at: 0.1) == .cancel)
    #expect(g.tick(at: 1) == nil)
  }

  @Test func fnUsedAsModifierCancels() {
    var g = FnGesture()
    _ = g.fnDown(at: 0)
    #expect(g.otherKey(at: 0.05) == .cancel)   // fn+← before the threshold
    #expect(g.tick(at: 0.3) == nil)
    #expect(g.fnUp(at: 0.4) == nil)
  }

  @Test func keyDuringDictationCancels() {
    var g = FnGesture()
    _ = g.fnDown(at: 0)
    _ = g.tick(at: 0.3)
    #expect(g.otherKey(at: 2) == .cancel)
    #expect(g.fnUp(at: 3) == nil)
  }

  @Test func warnsThenCommitsAtTheCap() {
    var g = FnGesture()
    _ = g.fnDown(at: 0)
    _ = g.tick(at: 0.3)
    #expect(g.tick(at: 109) == nil)
    #expect(g.tick(at: 110) == .capWarning)
    #expect(g.tick(at: 111) == nil)
    #expect(g.tick(at: 120) == .commit)
    #expect(g.fnUp(at: 121) == nil)
  }

  @Test func repeatedFnDownIsIgnoredAndResetGoesIdle() {
    var g = FnGesture()
    _ = g.fnDown(at: 0)
    #expect(g.fnDown(at: 0.1) == nil)
    g.reset()
    #expect(g.tick(at: 1) == nil)
    #expect(g.fnUp(at: 1) == nil)
    #expect(g.fnDown(at: 2) == .arm)
  }
}
