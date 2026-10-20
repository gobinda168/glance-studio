import AppKit
import GlanceCore
import GlanceKit
import WebKit

/// Spec 2026-10-11-needs-input-orb-design.md §2: while a Claude prompt is pending and no Glance orb is on screen, an
/// orb floats over every app (bottom right of the mouse's screen, or where the user dragged it). Never key, never
/// in Mission Control; a click opens the prompt cards. It doesn't register with `OrbAttention`: it only shows while
/// no registered orb does.
@MainActor
final class NeedsYouOrb: NSObject, WKNavigationDelegate {
    static let shared = NeedsYouOrb()
    static let side = DockGeometry.orbDiameter + 2 * DockGeometry.orbHalo

    private var panel: NSPanel?
    private var web: WKWebView?
    private var handle: DragHandle?
    private var ready = false
    private var mode = ""
    private var pending = false
    private var timer: Timer?

    func update(pending: Bool) {
        self.pending = pending
        if pending, timer == nil {
            // Studio's orbs come and go with occlusion, which posts nothing: look again every second.
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { NeedsYouOrb.shared.refresh() }
            }
        } else if !pending {
            timer?.invalidate()
            timer = nil
        }
        refresh()
    }

    private func refresh() {
        guard pending, !OrbAttention.anyOrbVisible else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? make()
        if !panel.isVisible {
            panel.setFrameOrigin(origin())
            panel.orderFrontRegardless()
        }
        apply()
    }

    /// Where the user last dropped it, while that's on a screen; else the bottom right of the mouse's screen.
    private func origin() -> CGPoint {
        let size = CGSize(width: Self.side, height: Self.side)
        if let saved = Prefs.needsYouOrbOrigin,
           NSScreen.screens.contains(where: { $0.visibleFrame.contains(NSRect(origin: saved, size: size)) }) {
            return saved
        }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        return CGPoint(x: visible.maxX - Self.side - 24, y: visible.minY + 24)
    }

    private func make() -> NSPanel {
        let frame = NSRect(x: 0, y: 0, width: Self.side, height: Self.side)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                            defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let web = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]
        web.loadFileURL(Resources.web.appendingPathComponent("orb.html"), allowingReadAccessTo: Resources.web)
        let handle = DragHandle(frame: frame)
        handle.autoresizingMask = [.width, .height]
        let container = NSView(frame: frame)
        container.addSubview(web)
        container.addSubview(handle)
        panel.contentView = container
        NotificationCenter.default.addObserver(forName: OrbAttention.changed, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NeedsYouOrb.shared.apply() }
        }
        self.panel = panel
        self.web = web
        self.handle = handle
        return panel
    }

    /// The orbs' shared mode (`waiting` while a prompt is pending) and tooltip ("my-app needs you: Bash command").
    private func apply() {
        handle?.toolTip = OrbAttention.tooltip
        let mode = OrbAttention.mode("idle")
        guard ready, mode != self.mode else { return }
        self.mode = mode
        web?.evaluateJavaScript("void glanceOrb.state('\(mode)')", completionHandler: nil)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            ready = true
            mode = ""
            apply()
        }
    }

    /// Click: the prompt cards. Drag: move the orb, and remember where. Only the orb itself (and a little around it)
    /// takes the mouse, not the whole glow.
    private final class DragHandle: NSView {
        private var start: NSPoint?
        private var origin: NSPoint = .zero
        private var moved = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            let reach = DockGeometry.orbDiameter / 2 + 6
            return hypot(local.x - bounds.midX, local.y - bounds.midY) <= reach ? self : nil
        }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

        override func mouseDown(with event: NSEvent) {
            start = NSEvent.mouseLocation
            origin = window?.frame.origin ?? .zero
            moved = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start, let window else { return }
            let now = NSEvent.mouseLocation
            let dx = now.x - start.x, dy = now.y - start.y
            if !moved, hypot(dx, dy) < 3 { return }
            moved = true
            window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
        }

        override func mouseUp(with event: NSEvent) {
            defer { start = nil; moved = false }
            guard start != nil else { return }
            if moved { Prefs.needsYouOrbOrigin = window?.frame.origin } else { _ = OrbAttention.orbClicked() }
        }
    }
}
