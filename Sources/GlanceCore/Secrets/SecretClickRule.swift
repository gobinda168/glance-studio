import CoreGraphics
import Foundation

/// Whether an Allow on the secret approval card comes from a real click on that very button (spec "Approval card").
/// A script pressing the button through Accessibility (AXPress, e.g. Claude's osascript under Studio's grant) runs its
/// action without a mouse event reaching the card's panel, so it never passes. Only the panel's own mouse events count:
/// not the button's pressed look, which nothing guarantees an AXPress leaves off.
///
/// Times are system uptime: `NSEvent.timestamp` and `ProcessInfo.systemUptime` share that clock. Points and frames are
/// in the card's top-down space (origin at the top left of the panel's content, y growing down), the space SwiftUI
/// reports the buttons' frames in; `topDown` turns an AppKit point into it.
///
/// Known limit: a process that may post synthetic `CGEvent` mouse clicks (it needs Accessibility too) produces real
/// mouse events here. They aren't filtered out (their markers aren't verified); the 1 s arming, the scope named on the
/// button and in the Touch ID reason, and the finger itself remain the gate.
public enum SecretClickRule {
  /// How recent the mouse-up must be for an Allow (below the card's 1 s arm delay).
  public static let clickWindow: TimeInterval = 0.4

  /// A left mouse-down or mouse-up the card's panel received.
  public struct Mouse: Equatable, Sendable {
    public var time: TimeInterval
    public var point: CGPoint

    public init(time: TimeInterval, point: CGPoint) {
      self.time = time
      self.point = point
    }
  }

  /// Accepts only if the last mouse-down came after arming, the mouse-up came at or after it and within `clickWindow`
  /// of `now`, and both lie inside this button's `frame`. Down and up may be milliseconds apart (a trackpad tap) and
  /// the action may run late (a busy main thread); a press dragged off the button, or begun on another one, fails.
  public static func accepts(armedAt: TimeInterval, now: TimeInterval, down: Mouse?, up: Mouse?,
                             frame: CGRect?) -> Bool {
    guard let down, let up, let frame, now - up.time <= clickWindow else { return false }
    return down.time > armedAt && up.time >= down.time && frame.contains(down.point) && frame.contains(up.point)
  }

  /// An AppKit point in a view's own coordinates turned into that view's top-down space. AppKit views count y up from
  /// the bottom unless `flipped`; SwiftUI's spaces count it down from the top.
  public static func topDown(_ point: CGPoint, bounds: CGRect, flipped: Bool) -> CGPoint {
    CGPoint(x: point.x - bounds.minX, y: flipped ? point.y - bounds.minY : bounds.maxY - point.y)
  }
}

/// The card's click records: the panel's last left mouse-down and mouse-up, and each button's frame. An Allow that
/// passes `SecretClickRule` uses the mouse records up; one that fails leaves them, so an AXPress can't spend the user's
/// own click.
public struct SecretClicks<Scope: Hashable & Sendable>: Sendable {
  public private(set) var down: SecretClickRule.Mouse?
  public private(set) var up: SecretClickRule.Mouse?
  /// Each button's frame in the card's top-down space. Kept across `reset`: the buttons report it as they lay out.
  public var frames: [Scope: CGRect] = [:]

  public init() {}

  public mutating func mouseDown(_ mouse: SecretClickRule.Mouse) { down = mouse }
  public mutating func mouseUp(_ mouse: SecretClickRule.Mouse) { up = mouse }

  /// A new front card, or a Touch ID sheet put up or taken down: no click before it counts.
  public mutating func reset() {
    down = nil
    up = nil
  }

  /// Whether an Allow for `scope` is a real click on its button; all records are used up only when it is.
  public mutating func take(_ scope: Scope, armedAt: TimeInterval, now: TimeInterval) -> Bool {
    guard SecretClickRule.accepts(armedAt: armedAt, now: now, down: down, up: up, frame: frames[scope]) else {
      return false
    }
    reset()
    return true
  }
}
