import AppKit
import SwiftUI

/// A floating card's material (MASTER §2, Regular): Liquid Glass on macOS 26, the HUD blur before it. The content is
/// clipped to the card's shape first, so a line along its edge (the meeting card's countdown, the update toast's
/// progress) follows the corners. Shared by the meeting card and the update toast.
struct GlassSurface<S: Shape>: ViewModifier {
  let shape: S

  func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      content.clipShape(shape).glassEffect(.regular, in: shape)
    } else {
      content.background(HUDBlur()).clipShape(shape)
    }
  }
}

private struct HUDBlur: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .hudWindow
    view.blendingMode = .behindWindow
    view.state = .active
    return view
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
