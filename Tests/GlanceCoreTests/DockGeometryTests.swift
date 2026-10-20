import CoreGraphics
import Testing
@testable import GlanceCore

@Test func docksInsideTheRightOfTheTerminalWindow() {
  // AX frame: top-left origin. A 1600x1000 window at (100, 50) on a 1080pt-tall primary screen.
  let frame = DockGeometry.panelFrame(axWindow: CGRect(x: 100, y: 50, width: 1600, height: 1000), primaryScreenHeight: 1080)
  #expect(frame.width == DockGeometry.width)
  #expect(frame.maxX == 100 + 1600 - DockGeometry.inset)
  #expect(frame.height == 1000 - DockGeometry.topInset - DockGeometry.inset)
  // AppKit y is measured from the bottom of the primary screen: 1080 - (50 + 1000) + inset.
  #expect(frame.minY == 30 + DockGeometry.inset)
}

@Test func narrowWindowsKeepMostOfTheTerminalVisible() {
  let wide = DockGeometry.panelFrame(axWindow: CGRect(x: 0, y: 0, width: 3000, height: 1600), primaryScreenHeight: 1700)
  #expect(wide.width == DockGeometry.width)
  let narrow = DockGeometry.panelFrame(axWindow: CGRect(x: 0, y: 0, width: 600, height: 600), primaryScreenHeight: 900)
  #expect(narrow.width == 360) // never more than 60% of the window
}

@Test func fallbackSitsOnTheScreenRightEdge() {
  let visible = CGRect(x: 0, y: 40, width: 1440, height: 860)
  let frame = DockGeometry.fallbackFrame(visibleScreen: visible)
  #expect(frame.width == DockGeometry.width)
  #expect(frame.maxX == 1440 - DockGeometry.inset)
  #expect(frame.minY == 40 + DockGeometry.inset)
  #expect(frame.height == 860 - 2 * DockGeometry.inset)
}

@Test func pillSitsCentredAboveTheTerminalInputOrTheScreenBottom() {
  let size = CGSize(width: 520, height: 56)
  let inTerminal = DockGeometry.pillFrame(window: CGRect(x: 100, y: 200, width: 1000, height: 700),
                                      visibleScreen: CGRect(x: 0, y: 0, width: 1440, height: 900), size: size)
  #expect(inTerminal == CGRect(x: 340, y: 272, width: 520, height: 56))
  let onScreen = DockGeometry.pillFrame(window: nil, visibleScreen: CGRect(x: 0, y: 25, width: 1440, height: 875), size: size)
  #expect(onScreen == CGRect(x: 460, y: 121, width: 520, height: 56))
}

// MARK: - Editors: the orb and its popover (AppKit coordinates)

@Test func theOrbSitsLeftOfClaudeCodesSideBarAboveTheStatusBar() {
  let window = CGRect(x: 100, y: 50, width: 1600, height: 1000)
  let center = DockGeometry.orbCenter(window: window, offset: nil)
  let r = DockGeometry.orbDiameter / 2
  #expect(center == CGPoint(x: 100 + 1600 - 336 - r, y: 50 + 36 + r))
}

@Test func inANarrowWindowTheOrbHugsTheCorner() {
  let window = CGRect(x: 0, y: 0, width: 800, height: 700)
  let r = DockGeometry.orbDiameter / 2
  #expect(DockGeometry.orbCenter(window: window, offset: nil).x == 800 - 24 - r)
}

@Test func aDraggedOrbKeepsItsPlaceRelativeToTheBottomRightCorner() {
  let window = CGRect(x: 0, y: 0, width: 1600, height: 1000)
  let offset = DockGeometry.orbOffset(center: CGPoint(x: 1500, y: 300), window: window)
  #expect(offset == CGVector(dx: 100, dy: 300))
  let moved = CGRect(x: 200, y: 100, width: 1400, height: 900)
  #expect(DockGeometry.orbCenter(window: moved, offset: offset) == CGPoint(x: 1500, y: 400))
}

@Test func theOrbNeverLeavesTheWindow() {
  let window = CGRect(x: 0, y: 0, width: 1000, height: 800)
  let center = DockGeometry.orbCenter(window: window, offset: CGVector(dx: 5000, dy: -50))
  let r = DockGeometry.orbDiameter / 2
  #expect(center.x - r >= window.minX)
  #expect(center.y - r >= window.minY)
  let top = DockGeometry.orbCenter(window: window, offset: CGVector(dx: 100, dy: 5000))
  #expect(top.y + r <= window.maxY - DockGeometry.topInset)
}

@Test func thePopoverOpensAboveTheOrbRightEdgesAligned() {
  let window = CGRect(x: 0, y: 0, width: 1600, height: 1000)
  let center = DockGeometry.orbCenter(window: window, offset: nil)
  let frame = DockGeometry.popoverFrame(window: window, orbCenter: center)
  let r = DockGeometry.orbDiameter / 2
  #expect(frame.width == DockGeometry.popoverWidth)
  #expect(frame.height == DockGeometry.popoverMaxHeight)
  #expect(frame.maxX == center.x + r)
  #expect(frame.minY == center.y + r + DockGeometry.popoverGap)
}

@Test func thePopoverIsShorterInAShortWindow() {
  let window = CGRect(x: 0, y: 0, width: 1600, height: 600)
  let frame = DockGeometry.popoverFrame(window: window, orbCenter: DockGeometry.orbCenter(window: window, offset: nil))
  #expect(frame.height == (600 * 0.72).rounded())
  #expect(frame.maxY <= window.maxY - DockGeometry.topInset)
}

@Test func anOrbNearTheTopOpensThePopoverBelowIt() {
  let window = CGRect(x: 0, y: 0, width: 1600, height: 1000)
  let center = DockGeometry.orbCenter(window: window, offset: CGVector(dx: 400, dy: 900))
  let frame = DockGeometry.popoverFrame(window: window, orbCenter: center)
  #expect(frame.maxY == center.y - DockGeometry.orbDiameter / 2 - DockGeometry.popoverGap)
  #expect(frame.minY >= window.minY + DockGeometry.inset)
}

@Test func anOrbNearTheLeftEdgeKeepsThePopoverInsideTheWindow() {
  let window = CGRect(x: 0, y: 0, width: 1600, height: 1000)
  let center = DockGeometry.orbCenter(window: window, offset: CGVector(dx: 1560, dy: 60))
  let frame = DockGeometry.popoverFrame(window: window, orbCenter: center)
  #expect(frame.minX == window.minX + DockGeometry.inset)
}
