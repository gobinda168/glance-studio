import AppKit
import GhosttyKit
import SwiftUI

/// A borderless panel over a terminal window for the suggestions' popups (spec "Look"): it never takes the key
/// window from the terminal, so typing keeps going to the shell, and it sits on screen near the cursor, never clipped
/// by a narrow split.
@MainActor
final class ShellPopup {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// Lets a click land on a row of a panel that isn't key.
    private final class ClickThroughHosting<Content: View>: NSHostingView<Content> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private let panel: Panel
    private(set) weak var parent: NSWindow?

    init<Content: View>(_ content: Content) {
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // the card draws its own
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.contentView = ClickThroughHosting(rootView: content)
    }

    var isVisible: Bool { panel.isVisible }

    /// Shows the panel at `size` next to `anchor` (screen coordinates): below it when it fits on the screen, else
    /// above (or above first when `preferAbove`). The visible card sits `margin` inside the panel (room for its
    /// shadow); `leading` is how far left of the anchor the panel's edge goes.
    func show(over window: NSWindow, anchor: NSRect, size: NSSize, leading: CGFloat = 0, margin: CGFloat = 0,
              preferAbove: Bool = false) {
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let gap: CGFloat = 2
        // Below: the card's top edge just under the cursor's cell. Above: its bottom edge just over it.
        let below = NSPoint(x: anchor.minX - leading, y: anchor.minY - gap - size.height + margin)
        let above = NSPoint(x: anchor.minX - leading, y: anchor.maxY + gap - margin)
        let fitsBelow = below.y + margin >= screen.minY
        let fitsAbove = above.y + size.height - margin <= screen.maxY
        var origin = preferAbove ? (fitsAbove || !fitsBelow ? above : below) : (fitsBelow || !fitsAbove ? below : above)
        isAboveAnchor = origin.y == above.y
        origin.x = min(max(origin.x, screen.minX - margin + 4), screen.maxX - size.width + margin - 4)
        origin.y = min(max(origin.y, screen.minY - margin), screen.maxY - size.height + margin)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if parent !== window {
            parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
            parent = window
        }
        panel.orderFront(nil)
    }

    /// Resizes in place, keeping the edge nearest the anchor where it is.
    func resize(to size: NSSize) {
        guard panel.isVisible, panel.frame.size != size else { return }
        var frame = panel.frame
        // Above the cursor it keeps its bottom edge (grows upward); below, its top edge.
        if !isAboveAnchor { frame.origin.y += frame.height - size.height }
        frame.size = size
        panel.setFrame(frame, display: true)
    }

    private var isAboveAnchor = false

    func close() {
        parent?.removeChildWindow(panel)
        parent = nil
        panel.orderOut(nil)
    }
}

extension Ghostty.SurfaceView {
    /// The cursor's cell in screen coordinates (the rectangle macOS's input methods are given), or nil.
    var cursorScreenRect: NSRect? {
        guard let surface, let window else { return nil }
        var x: Double = 0, y: Double = 0
        var width: Double = cellSize.width, height: Double = cellSize.height
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        let viewRect = NSRect(x: x, y: frame.size.height - y, width: max(width, cellSize.width),
                              height: max(height, cellSize.height))
        return window.convertToScreen(convert(viewRect, to: nil))
    }
}
