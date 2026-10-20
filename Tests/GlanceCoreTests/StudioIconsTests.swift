import Testing
@testable import GlanceCore

@Test func everyCanvasIconParses() {
  for name in StudioIcons.Name.allCases {
    let shapes = StudioIcons.shapes(name)
    #expect(!shapes.isEmpty, "\(name) has no shapes")
    #expect(shapes.allSatisfy { !$0.segments.isEmpty }, "\(name) has a shape that didn't parse")
  }
}

@Test func theIconsAreDrawnOnTheCanvasGrid() {
  #expect(StudioIcons.grid == 24)
  #expect(StudioIcons.strokeWidth == 1.7)
  // The pull request icon: two rings, the hook, the stem, in the canvas's order.
  #expect(StudioIcons.shapes(.pullRequest).count == 4)
  #expect(StudioIcons.shapes(.pullRequest).first?.segments.first == .move(SVGPath.Point(21, 18)))
}

@Test func onlyTheDraftIconIsDashed() {
  let dashed = StudioIcons.Name.allCases.filter { name in StudioIcons.shapes(name).contains { !$0.dash.isEmpty } }
  #expect(dashed == [.pullRequestDraft])
  #expect(StudioIcons.shapes(.pullRequestDraft).last?.dash == [2, 2])
}

@Test func everyIconStaysOnItsGrid() {
  // A path typed wrong ("1.4l1.6" read as one number) throws points far off the 24-unit square.
  for name in StudioIcons.Name.allCases {
    for shape in StudioIcons.shapes(name) {
      for segment in shape.segments {
        let points: [SVGPath.Point]
        switch segment {
        case .move(let p), .line(let p): points = [p]
        case .curve(let c1, let c2, let p): points = [c1, c2, p]
        case .close: points = []
        }
        #expect(points.allSatisfy { $0.x >= -2 && $0.x <= 26 && $0.y >= -2 && $0.y <= 26 }, "\(name) leaves the grid")
      }
    }
  }
}

@Test func thePickerHasALockAndAFolder() {
  #expect(StudioIcons.shapes(.lock).count == 2)
  #expect(StudioIcons.shapes(.folder).count == 1)
}

@Test func settingsHasAWindowAMicAndLayers() {
  #expect(StudioIcons.shapes(.window).count == 4)
  #expect(StudioIcons.shapes(.mic).count == 3)
  #expect(StudioIcons.shapes(.layers).count == 3)
}

@Test func theKeyFieldsEyeShowsAndHides() {
  // Lucide's eye (the lids, the iris) and eye-off (three strokes and the slash), for a key field's Show and Hide.
  #expect(StudioIcons.shapes(.eye).count == 2)
  #expect(StudioIcons.shapes(.eyeOff).count == 4)
}
