import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The Command tab (spec 2026-11-01-command-center-design.md §5): one per window, in the tab list like Usage, showing
/// the board of every Claude session. It takes over the Worktrees strip item while `Feature.commandCenter` is on.
/// Nothing to save, so closing it never asks.
@MainActor
final class CommandTabController: NSWindowController, NSWindowDelegate, GlanceTabController, GlancePaneOwner,
    ObservableObject {
    static let kind = "command"

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
        window.title = "Command"
        window.contentView = PullRequestHostingView(rootView: CommandTabView(controller: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Opens the Command side bar and the Command tab of `parent`'s window, made when it has none.
    @discardableResult
    static func open(from parent: NSWindow?) -> CommandTabController? {
        guard StudioFeatures.shared.isOn(.commandCenter) else { return nil }
        SidebarModeModel.shared.show(.command)
        return GlanceTabHost.open(kind: kind, key: kind, from: parent) { CommandTabController() }
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

/// The Command tab: the side bar column, the board page, and the Glance pane.
struct CommandTabView: View {
    @ObservedObject var controller: CommandTabController
    @ObservedObject private var tabSidebar = TabSidebarModel.shared

    var body: some View {
        HStack(spacing: 0) {
            if tabSidebar.isOpen {
                SidebarColumn()
            }
            HSplitView {
                CommandPage()
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
