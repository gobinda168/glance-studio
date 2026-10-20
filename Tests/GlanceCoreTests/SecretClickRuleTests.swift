import CoreGraphics
import Foundation
import Testing
@testable import GlanceCore

@Suite struct SecretClickRuleTests {
  enum Scope: Hashable, Sendable { case once, session }
  typealias Mouse = SecretClickRule.Mouse

  /// Armed at uptime 100; the card's top-down layout: Deny at the left, then Allow for this session, then Allow once.
  let armedAt: TimeInterval = 100
  static let deny = CGRect(x: 14, y: 150, width: 60, height: 26)
  static let session = CGRect(x: 160, y: 150, width: 150, height: 26)
  static let once = CGRect(x: 318, y: 150, width: 90, height: 26)
  let onDeny = CGPoint(x: 40, y: 160)
  let onSession = CGPoint(x: 200, y: 160)
  let onOnce = CGPoint(x: 350, y: 162)
  let offButtons = CGPoint(x: 120, y: 60)

  func clicks() -> SecretClicks<Scope> {
    var clicks = SecretClicks<Scope>()
    clicks.frames = [.session: Self.session, .once: Self.once]
    return clicks
  }

  @Test func anAXPressWithNoMouseEventsIsRejected() {
    var clicks = clicks()
    do { let ok = clicks.take(.once, armedAt: armedAt, now: 105); #expect(!ok) }
    do { let ok = clicks.take(.session, armedAt: armedAt, now: 105); #expect(!ok) }
  }

  @Test func aClickInsideTheButtonIsAccepted() {
    var clicks = clicks()
    clicks.mouseDown(Mouse(time: 104.80, point: onOnce))
    clicks.mouseUp(Mouse(time: 104.92, point: onOnce))
    do { let ok = clicks.take(.once, armedAt: armedAt, now: 104.93); #expect(ok) }
  }

  @Test func aTapToClickWithDownAndUpTwoMillisecondsApartIsAccepted() {
    var clicks = clicks()
    clicks.mouseDown(Mouse(time: 104.000, point: onSession))
    clicks.mouseUp(Mouse(time: 104.002, point: onSession))
    do { let ok = clicks.take(.session, armedAt: armedAt, now: 104.01); #expect(ok) }
  }

  @Test func aBusyMainThreadThatHandlesTheClickLateIsAccepted() {
    var clicks = clicks()
    clicks.mouseDown(Mouse(time: 104.0, point: onOnce))
    clicks.mouseUp(Mouse(time: 104.1, point: onOnce))
    // The action runs 0.35 s after the mouse-up, still inside the click window.
    do { let ok = clicks.take(.once, armedAt: armedAt, now: 104.45); #expect(ok) }
  }

  @Test func aMouseDownBeforeArmingIsRejected() {
    var clicks = clicks()
    clicks.mouseDown(Mouse(time: 99.9, point: onOnce))
    clicks.mouseUp(Mouse(time: 100.2, point: onOnce))
    do { let ok = clicks.take(.once, armedAt: armedAt, now: 100.25); #expect(!ok) }
  }

  @Test func downOnDenyAndUpOnAllowIsRejected() {
    var clicks = clicks()
    clicks.mouseDown(Mouse(time: 104.0, point: onDeny))
    clicks.mouseUp(Mouse(time: 104.3, point: onOnce))
    do { let ok = clicks.take(.once, armedAt: armedAt, now: 104.31); #expect(!ok) }
  }

  @Test func pressingAndDraggingOffTheButtonIsRejected() {
    var clicks = clicks()
    clicks.mouseDown(Mouse(time: 104.0, point: onOnce))
    clicks.mouseUp(Mouse(time: 104.4, point: offButtons))
    do { let ok = clicks.take(.once, armedAt: armedAt, now: 104.41); #expect(!ok) }
  }

  @Test func aPressedLookWithTheMouseUpJustOffTheFrameIsRejected() {
    var clicks = clicks()
    // The button looked pressed (the down was on it), but the up landed a point past its right edge: whatever SwiftUI
    // made of it, only the panel's own events count.
    clicks.mouseDown(Mouse(time: 104.0, point: onOnce))
    clicks.mouseUp(Mouse(time: 104.05, point: CGPoint(x: Self.once.maxX + 1, y: onOnce.y)))
    do { let ok = clicks.take(.once, armedAt: armedAt, now: 104.06); #expect(!ok) }
  }

  @Test func aStaleMouseUpIsRejected() {
    var clicks = clicks()
    clicks.mouseDown(Mouse(time: 104.0, point: onOnce))
    clicks.mouseUp(Mouse(time: 104.1, point: onOnce))
    do { let ok = clicks.take(.once, armedAt: armedAt, now: 104.51); #expect(!ok) }
  }

  @Test func aClickOnTheOtherAllowIsRejectedForThisScope() {
    var clicks = clicks()
    clicks.mouseDown(Mouse(time: 104.0, point: onOnce))
    clicks.mouseUp(Mouse(time: 104.1, point: onOnce))
    do { let ok = clicks.take(.session, armedAt: armedAt, now: 104.15); #expect(!ok) }
    // That rejection used nothing up: the click still counts for its own button.
    do { let ok = clicks.take(.once, armedAt: armedAt, now: 104.16); #expect(ok) }
  }

  @Test func aRejectedAttemptDoesNotConsumeTheUsersLivePress() {
    var clicks = clicks()
    clicks.mouseDown(Mouse(time: 104.0, point: onOnce))
    // An AXPress while the user is still holding the button down: no mouse-up yet.
    do { let ok = clicks.take(.once, armedAt: armedAt, now: 104.05); #expect(!ok) }
    #expect(clicks.down == Mouse(time: 104.0, point: onOnce))
    clicks.mouseUp(Mouse(time: 104.1, point: onOnce))
    do { let ok = clicks.take(.once, armedAt: armedAt, now: 104.11); #expect(ok) }
  }

  @Test func anAcceptedClickIsUsedUp() {
    var clicks = clicks()
    clicks.mouseDown(Mouse(time: 104.0, point: onOnce))
    clicks.mouseUp(Mouse(time: 104.1, point: onOnce))
    do { let ok = clicks.take(.once, armedAt: armedAt, now: 104.12); #expect(ok) }
    // A script's press right after it has nothing left to ride on.
    do { let ok = clicks.take(.once, armedAt: armedAt, now: 104.13); #expect(!ok) }
    #expect(clicks.frames[.once] == Self.once)
  }

  @Test func noClickCountsWhileTheButtonsFrameIsUnknown() {
    var clicks = SecretClicks<Scope>()
    clicks.mouseDown(Mouse(time: 104.0, point: onOnce))
    clicks.mouseUp(Mouse(time: 104.1, point: onOnce))
    do { let ok = clicks.take(.once, armedAt: armedAt, now: 104.12); #expect(!ok) }
  }

  @Test func aStillHeldPressWithAnOldMouseUpIsRejected() {
    var clicks = clicks()
    clicks.mouseUp(Mouse(time: 103.9, point: onOnce))
    clicks.mouseDown(Mouse(time: 104.0, point: onOnce))
    do { let ok = clicks.take(.once, armedAt: armedAt, now: 104.05); #expect(!ok) }
  }

  @Test func aNewFrontCardForgetsTheClicksButKeepsTheFrames() {
    var clicks = clicks()
    clicks.mouseDown(Mouse(time: 104.0, point: onOnce))
    clicks.mouseUp(Mouse(time: 104.1, point: onOnce))
    clicks.reset()
    do { let ok = clicks.take(.once, armedAt: armedAt, now: 104.12); #expect(!ok) }
    #expect(clicks.frames[.once] == Self.once)
  }

  @Test func appKitPointsTurnTopDown() {
    let bounds = CGRect(x: 0, y: 0, width: 468, height: 250)
    // Unflipped (AppKit's default): y counts up from the bottom.
    #expect(SecretClickRule.topDown(CGPoint(x: 350, y: 88), bounds: bounds, flipped: false) == CGPoint(x: 350, y: 162))
    #expect(SecretClickRule.topDown(CGPoint(x: 0, y: 250), bounds: bounds, flipped: false) == .zero)
    // Flipped (y already counts down from the top).
    #expect(SecretClickRule.topDown(CGPoint(x: 350, y: 162), bounds: bounds, flipped: true) == CGPoint(x: 350, y: 162))
    // A bounds origin that isn't zero.
    let shifted = CGRect(x: 10, y: 20, width: 468, height: 250)
    #expect(SecretClickRule.topDown(CGPoint(x: 360, y: 108), bounds: shifted, flipped: false)
      == CGPoint(x: 350, y: 162))
    #expect(SecretClickRule.topDown(CGPoint(x: 360, y: 182), bounds: shifted, flipped: true) == CGPoint(x: 350, y: 162))
  }
}
