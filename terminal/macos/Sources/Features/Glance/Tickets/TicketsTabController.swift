import AppKit
import Combine
import GlanceCore
import GlanceKit
import SwiftUI
import WebKit

/// The Tickets tab (spec 2026-10-09-tickets-design.md, "Tickets page and side bar"): one per window, in the tab list
/// like Notifications, showing `TicketsPage`. Opening it shows the Tickets side bar and fetches when the tickets are
/// older than an hour. While it's the key window, ↑/↓ ↩ R and ⌘F act on the page.
@MainActor
final class TicketsTabController: NSWindowController, NSWindowDelegate, GlanceTabController, GlancePaneOwner,
    ObservableObject {
    static let kind = "tickets"

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
        window.title = "Tickets"
        window.contentView = PullRequestHostingView(rootView: TicketsTabView(controller: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Opens Tickets: the Tickets side bar, and the Tickets tab of `parent`'s window, made when it has none. With no
    /// parent, the tab already open comes forward.
    @discardableResult
    static func open(from parent: NSWindow?) -> TicketsTabController? {
        guard StudioFeatures.shared.isOn(.tickets) else { return nil }
        SidebarModeModel.shared.show(.tickets)
        if parent == nil, let open = GlanceTabHost.controllers(kind: kind).first as? TicketsTabController {
            open.showWindowSafely(nil)
            NSApp.activate(ignoringOtherApps: true)
            return open
        }
        return GlanceTabHost.open(kind: kind, key: kind, from: parent) { TicketsTabController() }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        GlanceTerminalHost.shared.focusChanged(self)
        startKeys()
        let asOf = TicketService.shared.book.asOf
        if asOf.map({ Date().timeIntervalSince($0) > 3600 }) ?? true { TicketService.shared.refresh() }
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

    /// The page's keys, only while this tab is the key window and nothing that takes typing has the focus.
    private func startKeys() {
        guard keys == nil else { return }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let taken = MainActor.assumeIsolated {
                guard let self, let window = self.window, event.window === window, !Self.typing(in: window)
                else { return false }
                return TicketsNavigation.shared.handle(event)
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

/// The Tickets tab: the side bar column, the page, and the Glance pane.
struct TicketsTabView: View {
    @ObservedObject var controller: TicketsTabController
    @ObservedObject private var tabSidebar = TabSidebarModel.shared

    var body: some View {
        HStack(spacing: 0) {
            if tabSidebar.isOpen {
                SidebarColumn()
            }
            HSplitView {
                TicketsPage()
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

/// View › Tickets (⌥⌘T), shown while the feature is on.
@MainActor
final class TicketsMenu: NSObject, NSMenuItemValidation {
    static let shared = TicketsMenu()

    private var item: NSMenuItem?
    private var watch: AnyCancellable?

    func install(in view: NSMenu) {
        let item = NSMenuItem(title: "Tickets", action: #selector(show), keyEquivalent: "t")
        item.keyEquivalentModifierMask = [.command, .option]
        item.target = self
        view.addItem(item)
        self.item = item
        watch = StudioFeatures.shared.$enabled.sink { [weak item] enabled in
            item?.isHidden = !enabled.contains(.tickets)
        }
    }

    @objc func show() {
        TicketsTabController.open(from: SettingsTabController.frontWindow)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool { StudioFeatures.shared.isOn(.tickets) }
}
