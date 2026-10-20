import CoreGraphics

/// Where the panel sits relative to the terminal window.
public enum DockGeometry {
  public static let inset: CGFloat = 8
  /// Leaves the terminal's title/tab bar uncovered.
  public static let topInset: CGFloat = 40
  /// The design's panel width.
  public static let width: CGFloat = 440

  /// The panel frame in AppKit coordinates (bottom-left origin) for a terminal window frame from
  /// Accessibility (top-left origin of the primary screen). The panel covers the right part of the window.
  public static func panelFrame(axWindow: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
    let width = min(Self.width, axWindow.width * 0.6).rounded()
    let height = axWindow.height - topInset - inset
    let bottom = primaryScreenHeight - axWindow.maxY + inset
    return CGRect(x: axWindow.maxX - inset - width, y: bottom, width: width, height: height)
  }

  /// Used without Accessibility permission: the right edge of the screen.
  public static func fallbackFrame(visibleScreen: CGRect) -> CGRect {
    return CGRect(x: visibleScreen.maxX - inset - width, y: visibleScreen.minY + inset,
                  width: width, height: visibleScreen.height - 2 * inset)
  }

  /// The dictation pill: centred near the bottom of the terminal window (just above its input), or of the screen.
  /// `window` is in AppKit coordinates.
  public static func pillFrame(window: CGRect?, visibleScreen: CGRect, size: CGSize) -> CGRect {
    let area = window ?? visibleScreen
    let lift: CGFloat = window == nil ? 96 : 72
    return CGRect(x: (area.midX - size.width / 2).rounded(), y: area.minY + lift, width: size.width, height: size.height)
  }

  // MARK: - Editors: the orb and its popover

  // In an editor Glance is an orb over the code, opening a popover above it (Claude Design v11, VS Code "orb"). All
  // frames here are in AppKit coordinates, and `window` is the editor's window.

  public static let orbDiameter: CGFloat = 46
  /// Room around the orb for its glow and ripples.
  public static let orbHalo: CGFloat = 18
  public static let popoverWidth: CGFloat = 400
  public static let popoverMaxHeight: CGFloat = 560
  /// Between the orb and the popover.
  public static let popoverGap: CGFloat = 10

  /// The orb's centre measured from the window's bottom-right corner: left of a docked Claude Code side bar (about
  /// 320pt) and above the status bar, as in the design. A narrow window has no room for both, so it hugs the corner.
  public static func defaultOrbOffset(window: CGSize) -> CGVector {
    let r = orbDiameter / 2
    return CGVector(dx: (window.width >= 1000 ? 336 : 24) + r, dy: 36 + r)
  }

  /// Keeps the whole orb inside the window, below its title bar.
  public static func clampOrbOffset(_ offset: CGVector, window: CGSize) -> CGVector {
    let r = orbDiameter / 2
    let dx = min(max(offset.dx, r + inset), max(r + inset, window.width - r - inset))
    let dy = min(max(offset.dy, r + inset), max(r + inset, window.height - topInset - r))
    return CGVector(dx: dx, dy: dy)
  }

  /// `offset` is where the user dragged it (`orbOffset`), nil for the default.
  public static func orbCenter(window: CGRect, offset: CGVector?) -> CGPoint {
    let o = clampOrbOffset(offset ?? defaultOrbOffset(window: window.size), window: window.size)
    return CGPoint(x: window.maxX - o.dx, y: window.minY + o.dy)
  }

  /// The offset to remember after a drag, so the orb keeps its place as the window moves and resizes.
  public static func orbOffset(center: CGPoint, window: CGRect) -> CGVector {
    clampOrbOffset(CGVector(dx: window.maxX - center.x, dy: center.y - window.minY), window: window.size)
  }

  /// Above the orb with right edges aligned; below it when the orb sits too high for that. Never outside the window.
  public static func popoverFrame(window: CGRect, orbCenter center: CGPoint) -> CGRect {
    let r = orbDiameter / 2
    let width = min(popoverWidth, window.width - 2 * inset)
    let tallest = min(popoverMaxHeight, (window.height * 0.72).rounded())
    let roomAbove = window.maxY - topInset - (center.y + r + popoverGap)
    let roomBelow = center.y - r - popoverGap - (window.minY + inset)
    let above = roomAbove >= tallest || roomAbove >= roomBelow
    let height = max(0, min(tallest, above ? roomAbove : roomBelow)).rounded()
    let y = above ? center.y + r + popoverGap : center.y - r - popoverGap - height
    let x = min(max(center.x + r - width, window.minX + inset), window.maxX - inset - width)
    return CGRect(x: x.rounded(), y: y.rounded(), width: width, height: height)
  }
}
