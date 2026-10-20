import Foundation

/// How wide the side bar beside the activity strip may be: a fixed column the user drags between these, 300 pt (the
/// PR canvas's side bar) at first.
public enum TabSidebarLayout {
  public static let minWidth: Double = 260
  public static let maxWidth: Double = 400
  public static let defaultWidth: Double = 300

  public static func clamp(_ width: Double) -> Double {
    guard width.isFinite else { return defaultWidth }
    return min(max(width, minWidth), maxWidth)
  }
}
