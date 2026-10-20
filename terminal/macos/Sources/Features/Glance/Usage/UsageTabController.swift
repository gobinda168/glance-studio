import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The Usage tab (spec "The Usage page"): one per window, in the tab list like Journal, showing `UsagePage`. Opening it
/// shows the Usage side bar and scans for anything new. Nothing to save, so closing it never asks.
@MainActor
final class UsageTabController: NSWindowController, NSWindowDelegate, GlanceTabController, GlancePaneOwner,
    ObservableObject {
    static let kind = "usage"

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
        window.title = "Usage"
        window.contentView = PullRequestHostingView(rootView: UsageTabView(controller: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Opens Usage on `period` (today's day, week or month), or where it was: the Usage side bar, and the Usage tab of
    /// `parent`'s window, made when it has none. With no parent, the tab already open comes forward.
    @discardableResult
    static func open(period: UsagePeriod.Kind? = nil, from parent: NSWindow?) -> UsageTabController? {
        if let period { UsageNavigation.shared.show(period) }
        SidebarModeModel.shared.show(.usage)
        if parent == nil, let open = GlanceTabHost.controllers(kind: kind).first as? UsageTabController {
            open.showWindowSafely(nil)
            NSApp.activate(ignoringOtherApps: true)
            return open
        }
        return GlanceTabHost.open(kind: kind, key: kind, from: parent) { UsageTabController() }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        GlanceTerminalHost.shared.focusChanged(self)
        UsageService.shared.scan()
    }

    func windowWillClose(_ notification: Notification) {
        GlanceTabHost.closed(self)
        DispatchQueue.main.async { [weak window] in MainActor.assumeIsolated { window?.contentView = nil } }
    }
}

/// The Usage tab: the side bar column, the page, and the Glance pane.
struct UsageTabView: View {
    @ObservedObject var controller: UsageTabController
    @ObservedObject private var tabSidebar = TabSidebarModel.shared

    var body: some View {
        HStack(spacing: 0) {
            if tabSidebar.isOpen {
                SidebarColumn()
            }
            HSplitView {
                UsagePage()
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
