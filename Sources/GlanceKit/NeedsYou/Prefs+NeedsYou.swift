import CoreGraphics
import Foundation
import GlanceCore

/// Settings → Orb channel → "When Claude needs you" (spec 2026-10-11-needs-input-orb-design.md §5).
extension Prefs {
  public static var needsYouOpen: NeedsYouOpen {
    get { defaults.string(forKey: "needsYouOpen").flatMap(NeedsYouOpen.init(rawValue:)) ?? .glow }
    set { defaults.set(newValue.rawValue, forKey: "needsYouOpen") }
  }

  /// Where the user dragged the floating orb (its window's origin); nil until they do.
  public static var needsYouOrbOrigin: CGPoint? {
    get {
      guard let values = defaults.array(forKey: "needsYouOrbOrigin") as? [Double], values.count == 2 else { return nil }
      return CGPoint(x: values[0], y: values[1])
    }
    set { defaults.set(newValue.map { [Double($0.x), Double($0.y)] }, forKey: "needsYouOrbOrigin") }
  }
}
