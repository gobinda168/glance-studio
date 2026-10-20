import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The Meetings tab (spec 2026-10-09-meeting-notes-design.md): one per window, in the tab list like Journal, showing
/// the page `MeetingsNavigation` holds. Opening it shows the Meetings side bar. Nothing to save, so closing it never
/// asks; a recording goes on without it.
@MainActor
final class MeetingsTabController: NSWindowController, NSWindowDelegate, GlanceTabController, GlancePaneOwner,
    ObservableObject {
    static let kind = "meetings"

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
        window.title = "Meetings"
        window.contentView = PullRequestHostingView(rootView: MeetingsTabView(controller: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Opens Meetings on `page` (or where it was): the Meetings side bar, and the Meetings tab of `parent`'s window,
    /// made when it has none. With no parent, the tab already open comes forward.
    @discardableResult
    static func open(_ page: MeetingsNavigation.Page? = nil, from parent: NSWindow?) -> MeetingsTabController? {
        MeetingNotesLibrary.shared.load()
        if let page { MeetingsNavigation.shared.show(page) }
        SidebarModeModel.shared.show(.meetings)
        if parent == nil, let open = GlanceTabHost.controllers(kind: kind).first as? MeetingsTabController {
            open.showWindowSafely(nil)
            NSApp.activate(ignoringOtherApps: true)
            return open
        }
        return GlanceTabHost.open(kind: kind, key: kind, from: parent) { MeetingsTabController() }
    }

    /// Starts recording now and shows it: from the side bar, the start page, or the meeting nudge.
    static func record(title: String? = nil, eventID: String? = nil, from parent: NSWindow?) {
        let recorder = MeetingRecorder.shared
        if !recorder.isBusy { recorder.start(title: title, eventID: eventID) }
        if let record = recorder.record { open(.meeting(record.id), from: parent) }
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

/// The Meetings tab: the side bar column, the page, and the Glance pane.
struct MeetingsTabView: View {
    @ObservedObject var controller: MeetingsTabController
    @ObservedObject private var tabSidebar = TabSidebarModel.shared

    var body: some View {
        HStack(spacing: 0) {
            if tabSidebar.isOpen {
                SidebarColumn()
            }
            HSplitView {
                MeetingsPage()
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
