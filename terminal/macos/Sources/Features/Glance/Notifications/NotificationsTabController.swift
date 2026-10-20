import AppKit
import Combine
import GlanceCore
import GlanceKit
import SwiftUI
import WebKit

/// The Notifications tab (spec 2026-10-09-notifications-design.md, "Notifications page and side bar"): one per window,
/// in the tab list like Journal, showing `NotificationsPage`. Opening it shows the Notifications side bar too. Nothing
/// to save, so closing it never asks. While it's the key window, ↑/↓ ↩ R E and ⇧⌘A act on the page's rows.
@MainActor
final class NotificationsTabController: NSWindowController, NSWindowDelegate, GlanceTabController, GlancePaneOwner,
    ObservableObject {
    static let kind = "notifications"

    var tabKind: String { Self.kind }
    var tabKey: String { Self.kind }
    @Published var glancePaneOpen: Bool = GlanceTerminalHost.paneOpenDefault
    @Published var glancePlacement: PaneLayout.Placement?
    /// The pane follows the window's terminal, as on Home.
    var glanceDirectory: String? { HomeTabs.terminal(near: window)?.glanceDirectory }

    private var keys: Any?

    init() {
        let window = GlanceTabWindow()
        super.init(window: window)
        window.delegate = self
        window.title = "Notifications"
        window.contentView = PullRequestHostingView(rootView: NotificationsTabView(controller: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Opens Notifications: the Notifications side bar, and the Notifications tab of `parent`'s window, made when it
    /// has none. With no parent, the tab already open comes forward.
    @discardableResult
    static func open(from parent: NSWindow?) -> NotificationsTabController? {
        guard StudioFeatures.shared.isOn(.notifications) else { return nil }
        SidebarModeModel.shared.show(.notifications)
        if parent == nil, let open = GlanceTabHost.controllers(kind: kind).first as? NotificationsTabController {
            open.showWindowSafely(nil)
            NSApp.activate(ignoringOtherApps: true)
            return open
        }
        return GlanceTabHost.open(kind: kind, key: kind, from: parent) { NotificationsTabController() }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        GlanceTerminalHost.shared.focusChanged(self)
        startKeys()
    }

    func windowDidResignKey(_ notification: Notification) {
        stopKeys()
    }

    func windowWillClose(_ notification: Notification) {
        stopKeys()
        GlanceTabHost.closed(self)
        DispatchQueue.main.async { [weak window] in MainActor.assumeIsolated { window?.contentView = nil } }
    }

    // MARK: Keys

    /// The page's keys, only while this tab is the key window and nothing that takes typing has the focus (a field,
    /// the Glance pane's web view).
    private func startKeys() {
        guard keys == nil else { return }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let taken = MainActor.assumeIsolated {
                guard let self, let window = self.window, event.window === window, !Self.typing(in: window)
                else { return false }
                return NotificationsNavigation.shared.handle(event)
            }
            return taken ? nil : event
        }
    }

    private func stopKeys() {
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
    }

    private static func typing(in window: NSWindow) -> Bool {
        guard var view = window.firstResponder as? NSView else { return false }
        if view is NSText { return true }
        while let parent = view.superview {
            if view is WKWebView { return true }
            view = parent
        }
        return view is WKWebView
    }
}

/// The Notifications tab: the side bar column, the page, and the Glance pane.
struct NotificationsTabView: View {
    @ObservedObject var controller: NotificationsTabController
    @ObservedObject private var tabSidebar = TabSidebarModel.shared

    var body: some View {
        HStack(spacing: 0) {
            if tabSidebar.isOpen {
                SidebarColumn()
            }
            HSplitView {
                NotificationsPage()
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

/// What the page and the side bar show, shared by every window like Journal's page: the source filter, the selected
/// thread, whether done threads show, and whether Earlier is unfolded.
@MainActor
final class NotificationsNavigation: ObservableObject {
    static let shared = NotificationsNavigation()

    /// Catch me up's card: nothing (idle), Claude reading, the brief with the unread rows it was asked over (to tell
    /// when it's stale), or why it failed.
    enum CatchUpState: Equatable {
        case idle
        case running
        case ready(CatchUp.Brief, covered: Set<String>)
        case failed(String)
    }

    @Published var filter: Notice.Source? {
        didSet { if filter != oldValue { selection = nil } }
    }
    /// The selected row's thread key.
    @Published var selection: String?
    @Published var showDone = false
    /// Earlier is folded until asked for (and while folded, its rows take no keys).
    @Published var earlierOpen = false
    @Published var catchUp: CatchUpState = .idle

    private var hub: NotificationHub { NotificationHub.shared }
    private var catchUpRun: ClaudeOneShot.Run?

    /// Every unread thread, of all sources whatever the filter: what Catch me up reads.
    var unreadRows: [NoticeBook.Row] { hub.book.rows(filter: nil, showDone: false).filter(\.unread) }

    var catchingUp: Bool { catchUp == .running }

    /// Catch me up (⌘R): one Claude run (default model, no tools) over the unread rows; its brief replaces the card.
    func runCatchUp() {
        let rows = unreadRows
        guard !rows.isEmpty else { return }
        catchUpRun?.cancel()
        catchUp = .running
        let covered = Set(rows.map(\.id))
        catchUpRun = ClaudeRunner.run(prompt: CatchUp.prompt(rows: rows, now: Date()), tools: [], model: nil) {
            [weak self] event in
            guard let self else { return }
            switch event {
            case .done(let text):
                catchUp = CatchUp.brief(from: text).map { .ready($0, covered: covered) }
                    ?? .failed("Claude's answer wasn't a brief.")
                catchUpRun = nil
            case .failed(let why):
                catchUp = .failed(why)
                catchUpRun = nil
            case .text, .tool:
                break
            }
        }
    }

    /// ✕: the card goes, and a run under way stops.
    func dismissCatchUp() {
        catchUpRun?.cancel()
        catchUpRun = nil
        catchUp = .idle
    }

    /// A brief line: select its first row still in the inbox, unfolding Earlier, clearing a filter that hides it and
    /// showing done threads when that's where it went. The page scrolls to the selection.
    func show(_ line: CatchUp.Line) {
        let all = hub.book.rows(filter: nil, showDone: true)
        guard let row = line.ids.lazy.compactMap({ id in all.first { $0.id == id } }).first else { return }
        if let filter, row.newest.source != filter { self.filter = nil }
        if row.newest.state == .done && !row.unread { showDone = true }
        if !walkable().contains(where: { $0.id == row.id }) { earlierOpen = true }
        selection = row.id
    }

    /// Whether a brief line still has a row to go to.
    func hasRow(_ line: CatchUp.Line) -> Bool {
        let all = hub.book.rows(filter: nil, showDone: true)
        return line.ids.contains { id in all.contains { $0.id == id } }
    }

    func sections(now: Date = Date()) -> [NoticeBook.Section] {
        hub.book.sections(filter: filter, showDone: showDone, now: now)
    }

    /// The rows ↑/↓ walk, top to bottom: every section's, minus Earlier's while it's folded.
    func walkable(now: Date = Date()) -> [NoticeBook.Row] {
        sections(now: now).flatMap { $0.kind == .earlier && !earlierOpen ? [] : $0.rows }
    }

    var selectedRow: NoticeBook.Row? {
        guard let selection else { return nil }
        return hub.book.rows(filter: filter, showDone: showDone).first { $0.id == selection }
    }

    func select(_ row: NoticeBook.Row) { selection = row.id }

    func move(_ step: Int) {
        let rows = walkable()
        guard !rows.isEmpty else { return }
        guard let selection, let index = rows.firstIndex(where: { $0.id == selection }) else {
            self.selection = (step > 0 ? rows.first : rows.last)?.id
            return
        }
        self.selection = rows[max(0, min(rows.count - 1, index + step))].id
    }

    func open(_ row: NoticeBook.Row) {
        selection = row.id
        hub.open(row.newest)
    }

    func reply(_ row: NoticeBook.Row) {
        guard hub.canReply(row.newest) else { return }
        selection = row.id
        hub.reply(row.newest)
    }

    /// Done, and the selection steps to the row that takes its place.
    func done(_ row: NoticeBook.Row) {
        let rows = walkable()
        if selection == row.id, let index = rows.firstIndex(where: { $0.id == row.id }) {
            let rest = rows.filter { $0.id != row.id }
            selection = rest.isEmpty ? nil : rest[min(index, rest.count - 1)].id
        }
        hub.markDone(row)
        // A done row stays in view while done ones show; keep it selected then.
        if showDone, selection == nil { selection = row.id }
    }

    func markAllRead() { hub.markAllRead(filter: filter) }

    /// The page's keys: ↑/↓ move, ↩ Open, R Reply, E Done, ⇧⌘A Mark all read, ⌘R Catch me up, Esc clears the
    /// selection.
    func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "a" {
            markAllRead()
            return true
        }
        if flags == [.command], event.charactersIgnoringModifiers?.lowercased() == "r" {
            if !catchingUp { runCatchUp() }
            return true
        }
        guard flags.isEmpty else { return false }
        switch event.keyCode {
        case 125: move(1); return true                       // ↓
        case 126: move(-1); return true                      // ↑
        case 36, 76:                                         // ↩, enter
            guard let row = selectedRow else { return false }
            open(row)
            return true
        case 53:                                             // Esc
            guard selection != nil else { return false }
            selection = nil
            return true
        default:
            break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "r":
            guard let row = selectedRow, hub.canReply(row.newest) else { return false }
            reply(row)
            return true
        case "e":
            guard let row = selectedRow, row.newest.state != .done || row.unread else { return false }
            done(row)
            return true
        default:
            return false
        }
    }
}

/// View ▸ Notifications (⇧⌘N): shown, and its key live, only while the feature is on.
@MainActor
final class NotificationsMenu: NSObject, NSMenuItemValidation {
    static let shared = NotificationsMenu()

    private var item: NSMenuItem?
    private var watch: AnyCancellable?

    func install(in view: NSMenu) {
        let item = NSMenuItem(title: "Notifications", action: #selector(show), keyEquivalent: "n")
        item.keyEquivalentModifierMask = [.command, .shift]
        item.target = self
        view.addItem(item)
        self.item = item
        watch = StudioFeatures.shared.$enabled.sink { [weak item] enabled in
            item?.isHidden = !enabled.contains(.notifications)
        }
    }

    @objc func show() {
        NotificationsTabController.open(from: SettingsTabController.frontWindow)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool { StudioFeatures.shared.isOn(.notifications) }
}
