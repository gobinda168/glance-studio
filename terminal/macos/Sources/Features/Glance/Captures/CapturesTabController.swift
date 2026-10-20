import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The To-dos & Notes tab: one per window, in the tab list like Usage, showing what Ask Claude saved from selected text.
/// Opening it shows the To-dos & Notes side bar. Nothing to save, so closing it never asks.
@MainActor
final class CapturesTabController: NSWindowController, NSWindowDelegate, GlanceTabController, GlancePaneOwner,
    ObservableObject {
    static let kind = "captures"

    var tabKind: String { Self.kind }
    var tabKey: String { Self.kind }
    @Published var glancePaneOpen: Bool = GlanceTerminalHost.paneOpenDefault
    @Published var glancePlacement: PaneLayout.Placement?
    /// The pane follows the window's terminal, as on Home.
    var glanceDirectory: String? { HomeTabs.terminal(near: window)?.glanceDirectory }

    init() {
        let window = GlanceTabWindow()
        super.init(window: window)
        window.delegate = self
        window.title = "To-dos & Notes"
        window.contentView = PullRequestHostingView(rootView: CapturesTabView(controller: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Opens the tab on `page` (or where it was): the side bar, and the tab of `parent`'s window, made when it has none.
    /// With no parent, the tab already open comes forward.
    @discardableResult
    static func open(_ page: CapturesNavigation.Page? = nil, from parent: NSWindow?) -> CapturesTabController? {
        if let page { CapturesNavigation.shared.show(page) }
        SidebarModeModel.shared.show(.captures)
        if parent == nil, let open = GlanceTabHost.controllers(kind: kind).first as? CapturesTabController {
            open.showWindowSafely(nil)
            NSApp.activate(ignoringOtherApps: true)
            return open
        }
        return GlanceTabHost.open(kind: kind, key: kind, from: parent) { CapturesTabController() }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        GlanceTerminalHost.shared.focusChanged(self)
    }

    func windowWillClose(_ notification: Notification) {
        GlanceTabHost.closed(self)
        DispatchQueue.main.async { [weak window] in MainActor.assumeIsolated { window?.contentView = nil } }
    }
}

/// The tab: the side bar column, the page, and the Glance pane.
struct CapturesTabView: View {
    @ObservedObject var controller: CapturesTabController
    @ObservedObject private var tabSidebar = TabSidebarModel.shared

    var body: some View {
        HStack(spacing: 0) {
            if tabSidebar.isOpen {
                SidebarColumn()
            }
            HSplitView {
                CapturesPage()
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    .background(StudioColors.background)
                    .overlay(alignment: .bottomTrailing) {
                        if controller.glancePaneOpen && controller.glancePlacement == .floating {
                            GlanceFloatView()
                        }
                    }
                if controller.glancePaneOpen && controller.glancePlacement == .sidebar {
                    GlancePaneView()
                        .glanceSidebar()
                }
            }
        }
        .glancePlacement($controller.glancePlacement)
        .activityStrip()
    }
}
