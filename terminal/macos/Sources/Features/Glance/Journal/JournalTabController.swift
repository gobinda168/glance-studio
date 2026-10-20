import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The Journal tab (spec 2026-10-09-journal-design.md, "The Journal tab"): one per window, in the tab list like
/// Settings, showing the page `JournalNavigation` holds. Opening it shows the Journal side bar too, and collects today
/// so the page is fresh. Nothing to save, so closing it never asks.
@MainActor
final class JournalTabController: NSWindowController, NSWindowDelegate, GlanceTabController, GlancePaneOwner,
    ObservableObject {
    static let kind = "journal"

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
        window.title = "Journal"
        window.contentView = PullRequestHostingView(rootView: JournalTabView(controller: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Opens Journal on `page` (or where it was): the Journal side bar, and the Journal tab of `parent`'s window, made
    /// when it has none. With no parent, the tab already open comes forward.
    @discardableResult
    static func open(_ page: JournalNavigation.Page? = nil, from parent: NSWindow?) -> JournalTabController? {
        if let page { JournalNavigation.shared.show(page) }
        SidebarModeModel.shared.show(.journal)
        if parent == nil, let open = GlanceTabHost.controllers(kind: kind).first as? JournalTabController {
            open.showWindowSafely(nil)
            NSApp.activate(ignoringOtherApps: true)
            return open
        }
        return GlanceTabHost.open(kind: kind, key: kind, from: parent) { JournalTabController() }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        GlanceTerminalHost.shared.focusChanged(self)
        let journal = JournalService.shared
        journal.collect([journal.today])
    }

    func windowWillClose(_ notification: Notification) {
        GlanceTabHost.closed(self)
        DispatchQueue.main.async { [weak window] in MainActor.assumeIsolated { window?.contentView = nil } }
    }
}

/// The Journal tab: the side bar column, the page, and the Glance pane.
struct JournalTabView: View {
    @ObservedObject var controller: JournalTabController
    @ObservedObject private var tabSidebar = TabSidebarModel.shared

    var body: some View {
        HStack(spacing: 0) {
            if tabSidebar.isOpen {
                SidebarColumn()
            }
            HSplitView {
                JournalPage()
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

/// What the tab shows:
/// - the setup page until journaling has been turned on once (or while it's off with nothing kept);
/// - the store's error if it couldn't open;
/// - else the chosen page, under a "Journaling is off" line while it's off.
struct JournalPage: View {
    @ObservedObject private var journal = JournalService.shared
    @ObservedObject private var navigation = JournalNavigation.shared

    var body: some View {
        if let error = journal.storeError {
            JournalProblem(text: error)
        } else if !journal.settings.enabled && journal.summaries.isEmpty {
            JournalSetupView()
        } else {
            VStack(spacing: 0) {
                if !journal.settings.enabled {
                    JournalOffBanner()
                }
                switch navigation.page {
                case .today: JournalTodayView()
                case .insights: JournalInsightsView()
                case .day(let day): JournalDayView(day: day).id(day)
                }
            }
        }
    }
}

/// "Journaling is off · Turn on", above a page while journaling is off.
struct JournalOffBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("Journaling is off")
                .font(.studio(12.5, .medium))
                .foregroundStyle(StudioColors.noteInk)
            Text("·").foregroundStyle(StudioColors.muted)
            Button("Turn on") { JournalService.shared.setEnabled(true) }
                .buttonStyle(.plain)
                .font(.studio(12.5, .semibold))
                .foregroundStyle(StudioColors.coralInk)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .frame(height: 34)
        .background(StudioColors.note)
    }
}

/// The journal file couldn't be opened at all.
struct JournalProblem: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Journal can't open its file")
                .font(.studio(18, .semibold))
                .foregroundStyle(StudioColors.ink)
            Text(text)
                .font(.studio(12.5))
                .foregroundStyle(StudioColors.muted)
                .textSelection(.enabled)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
