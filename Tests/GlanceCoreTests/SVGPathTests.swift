import Testing
@testable import GlanceCore

private func pt(_ x: Double, _ y: Double) -> SVGPath.Point { SVGPath.Point(x, y) }

/// Segments equal within a thousandth of a unit (arcs and thirds don't come out exact).
private func near(_ a: [SVGPath.Segment]?, _ b: [SVGPath.Segment], tolerance: Double = 0.001) -> Bool {
  guard let a, a.count == b.count else { return false }
  func close(_ p: SVGPath.Point, _ q: SVGPath.Point) -> Bool {
    abs(p.x - q.x) <= tolerance && abs(p.y - q.y) <= tolerance
  }
  return zip(a, b).allSatisfy { pair in
    switch pair {
    case (.move(let p), .move(let q)), (.line(let p), .line(let q)): close(p, q)
    case (.curve(let p1, let p2, let p3), .curve(let q1, let q2, let q3)): close(p1, q1) && close(p2, q2) && close(p3, q3)
    case (.close, .close): true
    default: false
    }
  }
}

@Test func svgReadsAbsoluteLinesAndClose() {
  #expect(SVGPath.parse("M4 17 L10 11 H12 V20 Z")
    == [.move(pt(4, 17)), .line(pt(10, 11)), .line(pt(12, 11)), .line(pt(12, 20)), .close])
}

@Test func svgReadsRelativeCommandsAndImplicitLines() {
  // The canvas's terminal prompt: a relative move, then two implicit relative lines.
  #expect(SVGPath.parse("m4 17 6-6-6-6") == [.move(pt(4, 17)), .line(pt(10, 11)), .line(pt(4, 5))])
  #expect(near(SVGPath.parse("M12 16h.01"), [.move(pt(12, 16)), .line(pt(12.01, 16))]))
}

@Test func svgSplitsNumbersWrittenWithoutSeparators() {
  // The wrench: "1.4l1.6" ends a number at the letter.
  let wrench = SVGPath.parse("M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6")
  #expect(near(wrench.map { Array($0.suffix(1)) }, [.line(pt(16.3, 9.3))]))
  #expect(SVGPath.parse("M0 0l-2-2") == [.move(pt(0, 0)), .line(pt(-2, -2))])
  #expect(SVGPath.parse("M.5.5L1e1 2E0") == [.move(pt(0.5, 0.5)), .line(pt(10, 2))])
}

@Test func svgStartsARelativeMoveAfterCloseFromTheSubpathStart() {
  #expect(SVGPath.parse("M2 2h4zm1 1") == [.move(pt(2, 2)), .line(pt(6, 2)), .close, .move(pt(3, 3))])
}

@Test func svgTurnsAQuarterArcIntoOneCurve() {
  // The chat bubble's rounded corner: a quarter circle of radius 2 around (19, 15).
  let k = 2 * 0.5522847498
  #expect(near(SVGPath.parse("M21 15a2 2 0 0 1-2 2"),
               [.move(pt(21, 15)), .curve(pt(21, 15 + k), pt(19 + k, 17), pt(19, 17))]))
}

@Test func svgEndsALargeArcExactlyWhereItSays() throws {
  // The refresh icon's arc: more than half a circle, so several curves, ending on its point.
  let segments = try #require(SVGPath.parse("M21 12a9 9 0 1 1-3-6.7"))
  #expect(segments.count >= 4) // the move and at least three curves
  guard case .curve(_, _, let end) = segments.last else {
    Issue.record("the arc didn't end in a curve")
    return
  }
  #expect(abs(end.x - 18) < 0.0001 && abs(end.y - 5.3) < 0.0001)
}

@Test func svgConvertsQuadraticsAndReflectsSmoothCurves() {
  #expect(near(SVGPath.parse("M0 0Q10 10 20 0"),
               [.move(pt(0, 0)), .curve(pt(20.0 / 3, 20.0 / 3), pt(40.0 / 3, 20.0 / 3), pt(20, 0))]))
  #expect(near(SVGPath.parse("M0 0C0 10 10 10 10 0S20-10 20 0"),
               [.move(pt(0, 0)), .curve(pt(0, 10), pt(10, 10), pt(10, 0)),
                .curve(pt(10, -10), pt(20, -10), pt(20, 0))]))
}

@Test func svgRejectsWhatIsntPathData() {
  #expect(SVGPath.parse("M1") == nil)
  #expect(SVGPath.parse("X1 2") == nil)
  #expect(SVGPath.parse("M1 2 L") == nil)
  #expect(SVGPath.parse("L1 2") == nil) // path data starts with a move
  #expect(SVGPath.parse("M1 2z 3 4") == nil) // nothing repeats a close
  #expect(SVGPath.parse("") == [])
}

@Test func svgDrawsCirclesRectsAndLines() {
  let circle = SVGPath.circle(cx: 12, cy: 12, r: 3)
  #expect(circle.count == 6) // a move, four quarter curves, close
  #expect(circle.first == .move(pt(15, 12)))
  if case .curve(_, _, let end) = circle[1] { #expect(end == pt(12, 15)) } else { Issue.record("not a curve") }
  let rect = SVGPath.rect(x: 4, y: 8, width: 16, height: 12, rx: 2)
  #expect(rect.first == .move(pt(6, 8)))
  #expect(rect.count == 10)
  #expect(rect.last == .close)
  #expect(SVGPath.rect(x: 0, y: 0, width: 4, height: 2)
    == [.move(pt(0, 0)), .line(pt(4, 0)), .line(pt(4, 2)), .line(pt(0, 2)), .close])
  #expect(SVGPath.line(x1: 6, y1: 9, x2: 6, y2: 21) == [.move(pt(6, 9)), .line(pt(6, 21))])
}
