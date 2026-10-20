import Foundation

/// The Glance mark (`assets/logo/glance-mark.svg`) as geometry, in the SVG's units with the dial's centre at the
/// origin and y down: 24 ticks every 15°, each from the inner ring out to its own length, 17 coral and 7 amber, and
/// the orb set off-centre up and to the right. First Light builds this in 3D (spec 2026-10-10-first-light-onboarding).
public enum FirstLightMark {
  public enum Ink: Equatable, Sendable { case coral, amber }

  public struct Tick: Equatable, Sendable {
    /// Clockwise from twelve o'clock, in degrees.
    public let degrees: Double
    /// Where the tick ends, from the dial's centre.
    public let outer: Double
    public let ink: Ink

    /// The unit direction from the centre through the tick (y down).
    public var direction: (x: Double, y: Double) {
      let radians = degrees * .pi / 180
      return (sin(radians), -cos(radians))
    }
  }

  /// Every tick starts on this ring.
  public static let inner = 62.0
  /// The stroke's width (round caps).
  public static let width = 5.0
  /// The orb's centre from the dial's centre, and its radius.
  public static let orbOffset = (x: 9.0, y: -7.0)
  public static let orbRadius = 36.0
  /// The longest tick's end: the mark's outer radius.
  public static var outerRadius: Double { ticks.map(\.outer).max() ?? 94 }

  /// In SVG order of angle: (degrees, the line's far end `y2`, ink). The line runs from y = 38 to y2 on a 200-unit
  /// box centred at 100, so its outer radius is 100 − y2.
  private static let source: [(Double, Double, Ink)] = [
    (0, 28, .coral), (15, 24, .coral), (30, 18, .coral), (45, 12, .amber), (60, 20, .coral), (75, 26, .coral),
    (90, 22, .coral), (105, 14, .coral), (120, 8, .amber), (135, 16, .coral), (150, 24, .coral), (165, 28, .coral),
    (180, 26, .coral), (195, 6, .amber), (210, 14, .amber), (225, 12, .amber), (240, 12, .amber), (255, 22, .coral),
    (270, 14, .coral), (285, 22, .coral), (300, 26, .coral), (315, 12, .amber), (330, 18, .coral), (345, 14, .coral),
  ]

  public static let ticks: [Tick] = source.map { Tick(degrees: $0.0, outer: 100 - $0.1, ink: $0.2) }
}

/// Motion curves for First Light, as pure functions of time so a frame is a function of the clock.
public enum FirstLightCurve {
  /// A spring from 0 to 1 started at time 0: `response` is the period in seconds, `damping` the ratio (1 = no
  /// overshoot, MASTER's `.smooth` is about 0.86). Before 0 it is 0; it settles at 1.
  public static func spring(_ t: Double, response: Double, damping: Double) -> Double {
    guard t > 0 else { return 0 }
    let omega = 2 * .pi / response
    if damping >= 1 {
      return 1 - exp(-omega * t) * (1 + omega * t)
    }
    let decay = damping * omega
    let damped = omega * (1 - damping * damping).squareRoot()
    return 1 - exp(-decay * t) * (cos(damped * t) + decay / damped * sin(damped * t))
  }

  /// 0 before `start`, 1 after `start + duration`, linear between.
  public static func progress(_ t: Double, start: Double, duration: Double) -> Double {
    guard duration > 0 else { return t >= start ? 1 : 0 }
    return min(max((t - start) / duration, 0), 1)
  }

  /// Fast out, gentle landing (exponential ease-out).
  public static func easeOut(_ x: Double) -> Double {
    x >= 1 ? 1 : 1 - pow(2, -10 * x)
  }

  /// Slow start, fast end: things leaving.
  public static func easeIn(_ x: Double) -> Double {
    x * x * x
  }

  public static func easeInOut(_ x: Double) -> Double {
    x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
  }

  public static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double {
    a + (b - a) * t
  }
}

/// A value that springs from where it was to a new target, evaluated at any time (no per-frame state).
public struct FirstLightSpring: Equatable, Sendable {
  public private(set) var from: Double
  public private(set) var to: Double
  public private(set) var start: Double
  public var response: Double
  public var damping: Double

  public init(_ value: Double, response: Double = 0.6, damping: Double = 0.86) {
    from = value
    to = value
    start = 0
    self.response = response
    self.damping = damping
  }

  public func value(at t: Double) -> Double {
    FirstLightCurve.mix(from, to, FirstLightCurve.spring(t - start, response: response, damping: damping))
  }

  /// Heads for `target` from wherever it is at `t` (a retarget mid-flight starts from the current value).
  public mutating func set(_ target: Double, at t: Double) {
    guard target != to else { return }
    from = value(at: t)
    to = target
    start = t
  }

  /// Jumps (Reduce Motion).
  public mutating func snap(_ target: Double) {
    from = target
    to = target
    start = 0
  }

  public var target: Double { to }
}

extension FirstLightSpring {
  /// Springs to `target`, or jumps there when `instant` (Reduce Motion).
  mutating func go(_ target: Double, at t: Double, instant: Bool) {
    if instant { snap(target) } else { set(target, at: t) }
  }
}
