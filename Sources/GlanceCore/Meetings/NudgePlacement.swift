import CoreGraphics

/// Where the meeting nudge goes: top centre of the screen, just under the menu bar (and the notch), centred on the
/// whole screen so a side Dock doesn't push it off centre. Always on screen.
public enum NudgePlacement {
  public static let gap: CGFloat = 10
  static let inset: CGFloat = 8

  /// `screen` is the screen's frame, `visible` its visible frame (below the menu bar, beside the Dock).
  public static func frame(card: CGSize, screen: CGRect, visible: CGRect) -> CGRect {
    var x = screen.midX - card.width / 2
    x = max(min(x, visible.maxX - inset - card.width), visible.minX + inset)
    let y = max(visible.maxY - gap - card.height, visible.minY + inset)
    return CGRect(origin: CGPoint(x: x.rounded(), y: y.rounded()), size: card)
  }
}
