import Foundation

/// SVG path data (`d="…"`) and the basic shapes, as absolute lines and cubic curves: how Glance Studio draws the PR
/// Management canvas's line icons natively (spec 2026-10-07-pr-manager-design.md). Coordinates stay in the SVG's own
/// units; arcs and quadratic curves become cubic curves.
public enum SVGPath {
  public struct Point: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
      self.x = x
      self.y = y
    }
  }

  public enum Segment: Equatable, Sendable {
    case move(Point)
    case line(Point)
    /// Two control points, then the end.
    case curve(Point, Point, Point)
    case close
  }

  /// The segments of `data`. Nil when it isn't path data: an unknown command, a number missing, no move first, or
  /// numbers after a close.
  public static func parse(_ data: String) -> [Segment]? {
    var scanner = Scanner(Array(data.utf8))
    var segments: [Segment] = []
    var current = Point(0, 0)
    var start = Point(0, 0)
    // The previous curve's control point, for S (cubic) and T (quadratic) reflections.
    var lastCubic: Point?
    var lastQuad: Point?
    var command: UInt8?
    while true {
      scanner.skipSeparators()
      if scanner.atEnd { break }
      if let letter = scanner.letter() { command = letter }
      guard let letter = command else { return nil }
      let kind = letter | 0x20 // lower case
      if segments.isEmpty && kind != UInt8(ascii: "m") { return nil }
      let relative = letter == kind
      func point(_ x: Double, _ y: Double) -> Point {
        relative ? Point(current.x + x, current.y + y) : Point(x, y)
      }
      var cubic: Point?
      var quad: Point?
      switch kind {
      case UInt8(ascii: "m"):
        guard let x = scanner.number(), let y = scanner.number() else { return nil }
        current = point(x, y)
        start = current
        segments.append(.move(current))
        // More pairs after a move are lines.
        command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")
      case UInt8(ascii: "l"):
        guard let x = scanner.number(), let y = scanner.number() else { return nil }
        current = point(x, y)
        segments.append(.line(current))
      case UInt8(ascii: "h"):
        guard let x = scanner.number() else { return nil }
        current = Point(relative ? current.x + x : x, current.y)
        segments.append(.line(current))
      case UInt8(ascii: "v"):
        guard let y = scanner.number() else { return nil }
        current = Point(current.x, relative ? current.y + y : y)
        segments.append(.line(current))
      case UInt8(ascii: "c"):
        guard let x1 = scanner.number(), let y1 = scanner.number(), let x2 = scanner.number(),
              let y2 = scanner.number(), let x = scanner.number(), let y = scanner.number() else { return nil }
        let control1 = point(x1, y1), control2 = point(x2, y2), end = point(x, y)
        segments.append(.curve(control1, control2, end))
        current = end
        cubic = control2
      case UInt8(ascii: "s"):
        guard let x2 = scanner.number(), let y2 = scanner.number(), let x = scanner.number(),
              let y = scanner.number() else { return nil }
        let control1 = lastCubic.map { Point(2 * current.x - $0.x, 2 * current.y - $0.y) } ?? current
        let control2 = point(x2, y2), end = point(x, y)
        segments.append(.curve(control1, control2, end))
        current = end
        cubic = control2
      case UInt8(ascii: "q"):
        guard let x1 = scanner.number(), let y1 = scanner.number(), let x = scanner.number(),
              let y = scanner.number() else { return nil }
        let control = point(x1, y1), end = point(x, y)
        segments.append(quadratic(from: current, control: control, to: end))
        current = end
        quad = control
      case UInt8(ascii: "t"):
        guard let x = scanner.number(), let y = scanner.number() else { return nil }
        let control = lastQuad.map { Point(2 * current.x - $0.x, 2 * current.y - $0.y) } ?? current
        let end = point(x, y)
        segments.append(quadratic(from: current, control: control, to: end))
        current = end
        quad = control
      case UInt8(ascii: "a"):
        guard let rx = scanner.number(), let ry = scanner.number(), let rotation = scanner.number(),
              let large = scanner.flag(), let sweep = scanner.flag(),
              let x = scanner.number(), let y = scanner.number() else { return nil }
        let end = point(x, y)
        segments += arc(from: current, rx: rx, ry: ry, rotation: rotation, largeArc: large, sweep: sweep, to: end)
        current = end
      case UInt8(ascii: "z"):
        segments.append(.close)
        current = start
        // Nothing repeats a close: a number next is an error.
        command = nil
      default:
        return nil
      }
      lastCubic = cubic
      lastQuad = quad
    }
    return segments
  }

  /// A circle, clockwise from its rightmost point, as four quarter curves.
  public static func circle(cx: Double, cy: Double, r: Double) -> [Segment] {
    let k = r * kappa
    return [
      .move(Point(cx + r, cy)),
      .curve(Point(cx + r, cy + k), Point(cx + k, cy + r), Point(cx, cy + r)),
      .curve(Point(cx - k, cy + r), Point(cx - r, cy + k), Point(cx - r, cy)),
      .curve(Point(cx - r, cy - k), Point(cx - k, cy - r), Point(cx, cy - r)),
      .curve(Point(cx + k, cy - r), Point(cx + r, cy - k), Point(cx + r, cy)),
      .close,
    ]
  }

  /// A rectangle, its corners rounded by `rx` (at most half its width or height).
  public static func rect(x: Double, y: Double, width: Double, height: Double, rx: Double = 0) -> [Segment] {
    let r = min(max(rx, 0), width / 2, height / 2)
    let right = x + width, bottom = y + height
    guard r > 0 else {
      return [.move(Point(x, y)), .line(Point(right, y)), .line(Point(right, bottom)), .line(Point(x, bottom)), .close]
    }
    let k = r * kappa
    return [
      .move(Point(x + r, y)),
      .line(Point(right - r, y)),
      .curve(Point(right - r + k, y), Point(right, y + r - k), Point(right, y + r)),
      .line(Point(right, bottom - r)),
      .curve(Point(right, bottom - r + k), Point(right - r + k, bottom), Point(right - r, bottom)),
      .line(Point(x + r, bottom)),
      .curve(Point(x + r - k, bottom), Point(x, bottom - r + k), Point(x, bottom - r)),
      .line(Point(x, y + r)),
      .curve(Point(x, y + r - k), Point(x + r - k, y), Point(x + r, y)),
      .close,
    ]
  }

  public static func line(x1: Double, y1: Double, x2: Double, y2: Double) -> [Segment] {
    [.move(Point(x1, y1)), .line(Point(x2, y2))]
  }

  /// How far a quarter circle's control points sit from its ends, per unit of radius.
  private static let kappa = 0.5522847498

  private static func quadratic(from p0: Point, control q: Point, to p: Point) -> Segment {
    .curve(Point(p0.x + 2.0 / 3 * (q.x - p0.x), p0.y + 2.0 / 3 * (q.y - p0.y)),
           Point(p.x + 2.0 / 3 * (q.x - p.x), p.y + 2.0 / 3 * (q.y - p.y)), p)
  }

  /// An elliptical arc as cubic curves, a quarter turn at most each (SVG 1.1, appendix F.6). The last curve ends
  /// exactly on `p2`.
  static func arc(from p1: Point, rx: Double, ry: Double, rotation: Double, largeArc: Bool, sweep: Bool,
                  to p2: Point) -> [Segment] {
    if p1 == p2 { return [] }
    var rx = Swift.abs(rx), ry = Swift.abs(ry)
    if rx == 0 || ry == 0 { return [.line(p2)] }
    let phi = rotation * .pi / 180
    let cosPhi = cos(phi), sinPhi = sin(phi)
    let dx = (p1.x - p2.x) / 2, dy = (p1.y - p2.y) / 2
    let x1 = cosPhi * dx + sinPhi * dy
    let y1 = -sinPhi * dx + cosPhi * dy
    // Radii too small to reach are scaled up just enough.
    let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
    if lambda > 1 {
      rx *= lambda.squareRoot()
      ry *= lambda.squareRoot()
    }
    let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
    let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
    let factor = (largeArc == sweep ? -1.0 : 1.0) * max(0, numerator / denominator).squareRoot()
    let centerX = factor * rx * y1 / ry
    let centerY = -factor * ry * x1 / rx
    let cx = cosPhi * centerX - sinPhi * centerY + (p1.x + p2.x) / 2
    let cy = sinPhi * centerX + cosPhi * centerY + (p1.y + p2.y) / 2
    func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
      atan2(ux * vy - uy * vx, ux * vx + uy * vy)
    }
    let startAngle = angle(1, 0, (x1 - centerX) / rx, (y1 - centerY) / ry)
    var delta = angle((x1 - centerX) / rx, (y1 - centerY) / ry, (-x1 - centerX) / rx, (-y1 - centerY) / ry)
    if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }
    // A hair under a whole quarter turn stays one curve.
    let count = max(1, Int((Swift.abs(delta) / (.pi / 2) - 1e-9).rounded(.up)))
    let step = delta / Double(count)
    let t = 4.0 / 3 * tan(step / 4)
    func map(_ ux: Double, _ uy: Double) -> Point {
      Point(cx + rx * ux * cosPhi - ry * uy * sinPhi, cy + rx * ux * sinPhi + ry * uy * cosPhi)
    }
    var segments: [Segment] = []
    var theta = startAngle
    for index in 0..<count {
      let next = theta + step
      let control1 = map(cos(theta) - t * sin(theta), sin(theta) + t * cos(theta))
      let control2 = map(cos(next) + t * sin(next), sin(next) - t * cos(next))
      let end = index == count - 1 ? p2 : map(cos(next), sin(next))
      segments.append(.curve(control1, control2, end))
      theta = next
    }
    return segments
  }

  /// Reads path data byte by byte: command letters, numbers in SVG's compact forms ("1.4l", "-2-2", ".5.5", "1e1")
  /// and arc flags.
  private struct Scanner {
    let bytes: [UInt8]
    var index = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var atEnd: Bool { index >= bytes.count }

    mutating func skipSeparators() {
      while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D, 0x0C, UInt8(ascii: ",")].contains(bytes[index]) { index += 1 }
    }

    /// A command letter, when one is next.
    mutating func letter() -> UInt8? {
      guard index < bytes.count, "MmLlHhVvCcSsQqTtAaZz".utf8.contains(bytes[index]) else { return nil }
      defer { index += 1 }
      return bytes[index]
    }

    mutating func number() -> Double? {
      skipSeparators()
      let begin = index
      if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
      var digits = 0
      while index < bytes.count, isDigit(bytes[index]) {
        index += 1
        digits += 1
      }
      if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
        index += 1
        while index < bytes.count, isDigit(bytes[index]) {
          index += 1
          digits += 1
        }
      }
      guard digits > 0 else {
        index = begin
        return nil
      }
      if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
        var look = index + 1
        if look < bytes.count, bytes[look] == UInt8(ascii: "+") || bytes[look] == UInt8(ascii: "-") { look += 1 }
        if look < bytes.count, isDigit(bytes[look]) {
          index = look
          while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
      }
      return Double(String(decoding: bytes[begin..<index], as: UTF8.self))
    }

    /// An arc flag: one 0 or 1, which may run straight into the next number ("011 1").
    mutating func flag() -> Bool? {
      skipSeparators()
      guard index < bytes.count, bytes[index] == UInt8(ascii: "0") || bytes[index] == UInt8(ascii: "1") else { return nil }
      defer { index += 1 }
      return bytes[index] == UInt8(ascii: "1")
    }

    private func isDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }
  }
}
