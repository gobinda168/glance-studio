import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The Mods tab: one per window, in the tab list like To-dos & Notes. With no mod chosen it shows the library full
/// width with no side bar (spec 2026-10-14-fullwidth-libraries-design.md); on a mod, the Mods side bar comes back.
/// Nothing to save, so closing it never asks.
@MainActor
final class ModsTabController: NSWindowController, NSWindowDelegate, GlanceTabController, GlancePaneOwner,
    ObservableObject {
    static let kind = "mods"

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
        window.title = "Mods"
        window.contentView = PullRequestHostingView(rootView: ModsTabView(controller: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Opens the tab on `mod` with the side bar, on the library (`library`), or where it was: the tab of `parent`'s
    /// window, made when it has none. With no parent, the tab already open comes forward.
    @discardableResult
    static func open(_ mod: String? = nil, library: Bool = false, from parent: NSWindow?) -> ModsTabController? {
        if let mod {
            ModsNavigation.shared.show(mod)
            SidebarModeModel.shared.show(.mods)
        } else {
            if library { ModsNavigation.shared.show(nil) }
            SidebarModeModel.shared.follow(.mods)
        }
        ModStore.shared.reload()
        if parent == nil, let open = GlanceTabHost.controllers(kind: kind).first as? ModsTabController {
            open.showWindowSafely(nil)
            NSApp.activate(ignoringOtherApps: true)
            return open
        }
        return GlanceTabHost.open(kind: kind, key: kind, from: parent) { ModsTabController() }
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

/// The tab: the side bar column on a mod (never on the library), the page, and the Glance pane.
struct ModsTabView: View {
    @ObservedObject var controller: ModsTabController
    @ObservedObject private var tabSidebar = TabSidebarModel.shared
    @ObservedObject private var navigation = ModsNavigation.shared
    @ObservedObject private var store = ModStore.shared

    var body: some View {
        HStack(spacing: 0) {
            if tabSidebar.isOpen && store.entry(named: navigation.selected) != nil {
                SidebarColumn()
            }
            HSplitView {
                ModsPage()
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
