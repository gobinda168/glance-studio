import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The Settings tab (spec 2026-10-08-settings-design.md, "Where Settings lives"): one per window, in the tab list like
/// Home, showing the section `SettingsNavigation` holds. Opening it shows the Settings side bar too. Nothing to save,
/// so closing it never asks.
@MainActor
final class SettingsTabController: NSWindowController, NSWindowDelegate, GlanceTabController, GlancePaneOwner,
    ObservableObject {
    static let kind = "settings"

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
        window.title = "Settings"
        window.contentView = PullRequestHostingView(rootView: SettingsTabView(controller: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Opens Settings: the Settings side bar, and the Settings tab of `parent`'s window (made when it has none). With
    /// no parent (the built-in terminal off) the tab opens in a window of its own, or the one already open comes
    /// forward. On `section`, scrolled to `focus`, when given.
    @discardableResult
    static func open(section: SettingsSection? = nil, focus: String? = nil, from parent: NSWindow?) -> SettingsTabController? {
        if let section { SettingsNavigation.shared.show(section, focus: focus) }
        GlanceTerminalHost.shared.settings?.refresh()
        SidebarModeModel.shared.show(.settings)
        if parent == nil, let open = GlanceTabHost.controllers(kind: kind).first as? SettingsTabController {
            open.showWindowSafely(nil)
            NSApp.activate(ignoringOtherApps: true)
            return open
        }
        return GlanceTabHost.open(kind: kind, key: kind, from: parent) { SettingsTabController() }
    }

    /// The Studio window in front, when there is one: Settings opens as a tab there.
    static var frontWindow: NSWindow? {
        let candidates = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 } + NSApp.orderedWindows
        return candidates.first { $0 is TerminalWindow && $0.isVisible }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        GlanceTerminalHost.shared.focusChanged(self)
        // Permissions and keys change in System Settings and the Keychain while Settings is open.
        GlanceTerminalHost.shared.settings?.refresh()
    }

    func windowWillClose(_ notification: Notification) {
        GlanceTabHost.closed(self)
        // The view holds this controller, which holds the window: once it has closed, let go of the view.
        DispatchQueue.main.async { [weak window] in MainActor.assumeIsolated { window?.contentView = nil } }
    }
}

/// The Settings tab: the side bar column, the Settings page, and the Glance pane (a sidebar, or the floating orb).
struct SettingsTabView: View {
    @ObservedObject var controller: SettingsTabController
    @ObservedObject private var tabSidebar = TabSidebarModel.shared

    var body: some View {
        HStack(spacing: 0) {
            if tabSidebar.isOpen {
                SidebarColumn()
            }
            HSplitView {
                SettingsPage()
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
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
