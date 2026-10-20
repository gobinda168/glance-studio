import AppKit
import GlanceCore

/// Opens where the user left off after a relaunch, as a browser does (an update restarts the whole app). AppKit brings
/// the terminal windows back (their folders, split panes and tab groups, see `TerminalRestorableState`); this saves
/// the rest of each window's tabs (Home, the editors, Browser pages, pull requests, Tickets…) in the defaults and
/// opens them again around the terminals, in the same order, with the same tab in front.
@MainActor
enum TabRestore {
    private static let defaults = UserDefaults(suiteName: "dev.glance.Glance") ?? .standard
    private static let key = "tabRestore"
    /// Saving waits for the restore: a snapshot taken while the windows are still coming back would overwrite it.
    private static var ready = false
    private static var savePending = false

    // MARK: Saving

    /// Saves the tabs a moment after they last changed (a tab opened, closed, moved or selected).
    static func saveSoon() {
        guard ready, !savePending else { return }
        savePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated {
                savePending = false
                save()
            }
        }
    }

    /// Saves the tabs now (at quit, which an update does too).
    static func save() {
        guard ready else { return }
        guard let data = snapshot().encoded() else { return }
        defaults.set(data, forKey: key)
    }

    static func snapshot() -> TabSnapshot {
        var seen = Set<ObjectIdentifier>()
        var groups: [TabSnapshot.Group] = []
        var front: Int?
        let current = NSApp.keyWindow ?? NSApp.mainWindow
        for window in NSApp.windows {
            let windows = window.tabGroup?.windows ?? [window]
            guard let first = windows.first, seen.insert(ObjectIdentifier(first)).inserted else { continue }
            let tabs = windows.compactMap { tab(of: $0) }
            guard !tabs.isEmpty else { continue }
            let selected = window.tabGroup?.selectedWindow ?? window
            let index = windows.filter { tab(of: $0) != nil }.firstIndex(of: selected)
            if let current, windows.contains(current) { front = groups.count }
            groups.append(.init(tabs: tabs, selected: index))
        }
        return TabSnapshot(groups: groups, frontGroup: front)
    }

    private static func tab(of window: NSWindow) -> TabSnapshot.Tab? {
        if let terminal = window.windowController as? TerminalController {
            guard let surface = terminal.surfaceTree.first else { return nil }
            return .init(kind: TabSnapshot.Tab.terminal, surface: surface.id.uuidString)
        }
        guard let controller = window.windowController as? any GlanceTabController else { return nil }
        switch controller.tabKind {
        case HomeTabs.kind, TicketsTabController.kind, MeetingsTabController.kind, JournalTabController.kind,
             UsageTabController.kind, NotificationsTabController.kind, CapturesTabController.kind, ModsTabController.kind,
             AutomationsLibraryTabController.kind(agents: false), AutomationsLibraryTabController.kind(agents: true):
            return .init(kind: controller.tabKind)
        case EditorKind.razor.rawValue, EditorKind.studio.rawValue, PullRequestWindowController.kind:
            return .init(kind: controller.tabKind, key: controller.tabKey)
        case BrowserTabController.kind:
            // A saved app's tab, a Slack workspace and the like come back from their own places.
            guard let browser = controller as? BrowserTabController, browser.appID == nil else { return nil }
            switch browser.content {
            case .start: return nil
            case .web:
                // A blank page has nothing to come back to.
                guard let url = browser.state.url, url.absoluteString != "about:blank" else { return nil }
                return .init(kind: controller.tabKind, url: url.absoluteString)
            default: return nil
            }
        default:
            return nil
        }
    }

    // MARK: Restoring

    /// Opens the saved tabs around the terminal windows AppKit brought back, then calls `done` with whether it opened
    /// any (which also means the launch needs no window of its own). AppKit brings its windows back a moment after
    /// launch, so this waits for the terminals the snapshot names (a few seconds at most): a tab opened before its
    /// terminal exists would sit in a window of its own.
    static func restore(then done: @escaping (Bool) -> Void) {
        guard (NSApp.delegate as? AppDelegate)?.ghostty.config.windowSaveState != "never",
              let snapshot = TabSnapshot.decode(defaults.data(forKey: key)), !snapshot.isEmpty else {
            finish(false, done)
            return
        }
        let surfaces = snapshot.groups.flatMap(\.tabs).compactMap { $0.surface.flatMap(UUID.init(uuidString:)) }
        waitForTerminals(surfaces, attempts: 0) {
            finish(restore(snapshot), done)
        }
    }

    private static func finish(_ opened: Bool, _ done: (Bool) -> Void) {
        ready = true
        saveSoon()
        done(opened)
    }

    private static func waitForTerminals(_ surfaces: [UUID], attempts: Int, then body: @escaping () -> Void) {
        if attempts >= 30 || surfaces.allSatisfy({ terminal(showing: $0) != nil }) {
            body()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated { waitForTerminals(surfaces, attempts: attempts + 1, then: body) }
        }
    }

    private static func restore(_ snapshot: TabSnapshot) -> Bool {
        let sidebarOpen = TabSidebarModel.shared.isOpen
        let mode = SidebarModeModel.shared.mode
        var fronts: [NSWindow?] = []
        var opened = false
        GlanceTabHost.restoring = true
        for group in snapshot.groups {
            let (windows, front, made) = open(group)
            opened = opened || made
            arrange(windows)
            if let front { front.tabGroup?.selectedWindow = front }
            // A window whose terminals didn't come back shows once its tabs are in place.
            if let shown = front ?? windows.first, !shown.isVisible { shown.orderFront(nil) }
            fronts.append(front)
        }
        GlanceTabHost.restoring = false
        // Opening a tab shows its side bar; the one the user had, open or closed, is the one that stays.
        SidebarModeModel.shared.show(mode)
        TabSidebarModel.shared.isOpen = sidebarOpen
        if let index = snapshot.frontGroup, fronts.indices.contains(index), let window = fronts[index] {
            window.makeKeyAndOrderFront(nil)
        }
        TabSidebarModel.shared.refreshSoon()
        return opened
    }

    /// One saved window's tabs as windows, in order, with the one in front, and whether any was opened here (not a
    /// terminal AppKit already restored). Each tab opened here goes straight into its place in the window the
    /// terminals came back in, behind the tab in front: opened on its own it would show as a window of its own, and
    /// moved into place later its window would flash up as it left the group.
    private static func open(_ group: TabSnapshot.Group) -> (windows: [NSWindow], front: NSWindow?, opened: Bool) {
        var windows: [NSWindow] = []
        var front: NSWindow?
        var anchor = group.tabs.lazy.compactMap { $0.surface.flatMap(UUID.init(uuidString:)) }
            .compactMap { terminal(showing: $0)?.window }.first
        var previous: NSWindow? // the last tab in place, which the next one goes after
        var leading: [NSWindow] = [] // the tabs before the first terminal, which go before it
        var opened = false
        for (index, tab) in group.tabs.enumerated() {
            let window: NSWindow?
            if tab.isTerminal {
                window = tab.surface.flatMap(UUID.init(uuidString:)).flatMap(terminal(showing:))?.window
                if let window {
                    leading.forEach { window.addTabbedWindowSafely($0, ordered: .below) }
                    leading = []
                    previous = window
                }
            } else {
                window = open(tab, near: anchor)
                if let window {
                    opened = true
                    if let anchor, window !== anchor, window.tabGroup?.windows.count ?? 1 > 1,
                       window.tabGroup === anchor.tabGroup {
                        previous = window // already there (Home, opened a moment after launch)
                    } else if let after = previous {
                        after.addTabbedWindowSafely(window, ordered: .above)
                        previous = window
                    } else {
                        leading.append(window)
                    }
                }
            }
            guard let window else { continue }
            windows.append(window)
            anchor = anchor ?? window
            if index == group.front { front = window }
        }
        // None of the window's terminals came back: its first tab is the window, the rest go after it.
        if let first = leading.first {
            var previous = first
            for window in leading.dropFirst() {
                previous.addTabbedWindowSafely(window, ordered: .above)
                previous = window
            }
        }
        return (windows, front, opened)
    }

    private static func terminal(showing surface: UUID) -> TerminalController? {
        TerminalController.all.first { controller in controller.surfaceTree.contains { $0.id == surface } }
    }

    private static func open(_ tab: TabSnapshot.Tab, near anchor: NSWindow?) -> NSWindow? {
        switch tab.kind {
        case HomeTabs.kind:
            return HomeTabs.show(in: anchor)?.window
        case TicketsTabController.kind:
            return TicketsTabController.open(from: anchor)?.window
        case MeetingsTabController.kind:
            return MeetingsTabController.open(from: anchor)?.window
        case JournalTabController.kind:
            return JournalTabController.open(from: anchor)?.window
        case UsageTabController.kind:
            return UsageTabController.open(from: anchor)?.window
        case NotificationsTabController.kind:
            return NotificationsTabController.open(from: anchor)?.window
        case CapturesTabController.kind:
            return CapturesTabController.open(from: anchor)?.window
        case ModsTabController.kind:
            return ModsTabController.open(from: anchor)?.window
        case AutomationsLibraryTabController.kind(agents: false), AutomationsLibraryTabController.kind(agents: true):
            let agents = tab.kind == AutomationsLibraryTabController.kind(agents: true)
            return AutomationsLibraryTabController.open(agents: agents, from: anchor)?.window
        case EditorKind.razor.rawValue, EditorKind.studio.rawValue:
            // A folder that is gone has nothing to open.
            guard let root = tab.key, let kind = EditorKind(rawValue: tab.kind),
                  FileManager.default.fileExists(atPath: root) else { return nil }
            return EditorTabs.open(kind, root: root, from: anchor)?.window
        case PullRequestWindowController.kind:
            guard let key = tab.key, let hash = key.lastIndex(of: "#"),
                  let number = Int(key[key.index(after: hash)...]) else { return nil }
            return PullRequestWindowController.open(repository: String(key[..<hash]), number: number, root: nil,
                                                    from: anchor)?.window
        case BrowserTabController.kind:
            guard let url = tab.url.flatMap(URL.init(string:)), url.absoluteString != "about:blank" else { return nil }
            return BrowserTabController.open(url: url, from: anchor)?.window
        default:
            return nil
        }
    }

    /// Puts `windows` in one tab group in this order. Opening a tab puts it beside its parent, and a restored terminal
    /// may sit anywhere in its group, so each place from the left is filled in turn, the way a tab is moved.
    private static func arrange(_ windows: [NSWindow]) {
        guard let first = windows.first, windows.count > 1 else { return }
        for window in windows.dropFirst() where window.tabGroup == nil || window.tabGroup !== first.tabGroup {
            if let group = window.tabGroup, group.windows.count > 1 { group.removeWindow(window) }
            first.addTabbedWindowSafely(window, ordered: .above)
        }
        guard let group = first.tabGroup else { return }
        let selected = group.selectedWindow
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        for (index, window) in windows.enumerated() where group.windows.indices.contains(index) {
            guard group.windows[index] !== window else { continue }
            group.removeWindow(window)
            if index == 0 {
                group.windows[0].addTabbedWindowSafely(window, ordered: .below)
            } else {
                group.windows[index - 1].addTabbedWindowSafely(window, ordered: .above)
            }
        }
        if let selected { group.selectedWindow = selected }
        NSAnimationContext.endGrouping()
        (windows.first { $0.windowController is TerminalController }?.windowController as? TerminalController)?
            .relabelTabs()
    }
}
