import AppKit
import GlanceKit
import SwiftUI

/// Glance browser's floating window (spec 2026-10-14-agent-browser-design.md): above every app and Space, never
/// taking focus when it appears, dragged from its top strip, resized from any edge, and where the user left it next
/// time. Hiding it leaves the browser running.
@MainActor
final class AgentBrowserPanel: NSObject, NSWindowDelegate {
    static let shared = AgentBrowserPanel()

    private static let size = NSSize(width: 560, height: 420)
    private static let autosaveName = "GlanceAgentBrowserPanel"

    private var panel: NSPanel?
    private(set) var isShown = false

    /// Shows the panel without taking focus (a page opened), or brings it forward (the menu).
    func show() {
        let panel = self.panel ?? make()
        self.panel = panel
        isShown = true
        panel.orderFrontRegardless()
        if AgentBrowserBroker.shared.state == .off { AgentBrowserBroker.shared.start() }
    }

    func hide() {
        isShown = false
        AgentBrowserModel.shared.takingOver = false
        panel?.orderOut(nil)
    }

    func toggle() { isShown ? hide() : show() }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Glance Browser"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 320, height: 220)
        panel.delegate = self
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        let view = AgentBrowserView(model: .shared, broker: .shared) { [weak self] in self?.hide() }
        panel.contentView = NSHostingView(rootView: view)
        if !panel.setFrameUsingName(Self.autosaveName) { place(panel) }
        panel.setFrameAutosaveName(Self.autosaveName)
        return panel
    }

    /// First time: the right of the screen under the mouse, vertically centred, clear of the Dock.
    private func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return panel.center() }
        panel.setFrameOrigin(NSPoint(x: area.maxX - Self.size.width - 24, y: area.midY - Self.size.height / 2))
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }
}
