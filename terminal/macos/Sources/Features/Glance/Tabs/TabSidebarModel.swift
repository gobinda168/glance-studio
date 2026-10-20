import AppKit
import Combine
import GlanceCore

/// One row of the tab sidebar.
struct TabRow: Identifiable {
    /// What a tab holds, for its icon chip's tint: terminals cyan, editors violet, Home the whole aurora. `chat` is a
    /// Browser tab.
    enum Kind: Equatable {
        case terminal, editor, home, other, chat
    }

    let window: NSWindow
    var id: ObjectIdentifier { ObjectIdentifier(window) }
    let icon: String
    let title: String
    let folder: String
    let branch: String?                    // NEW
    let command: String?                   // NEW
    let claude: TabStatusBook.Status       // NEW
    let bell: Bool                         // NEW
    /// Terminals in the tab (split panes); 1 when it isn't split.
    var panes = 1
    let isSelected: Bool
    var kind: Kind = .terminal
    /// The canvas icon on the row's tile.
    var studioIcon: StudioIcons.Name = .terminal
}

/// The tab sidebar's shared state. Every tab window draws its own sidebar view, so switching tabs swaps windows; the
/// open state, the width, the live per-tab data and the row computation live here and are shared by all of them.
@MainActor
final class TabSidebarModel: ObservableObject {
    static let shared = TabSidebarModel()

    private static let defaults = UserDefaults(suiteName: "dev.glance.Glance") ?? .standard

    /// Bumped whenever tabs, titles, folders, live data or the selection may have changed, so the views that list tabs
    /// redraw. It lives in its own object: every window's root view observes this model for `isOpen` and `width`, and
    /// a title changing on every prompt mustn't redraw all of them.
    final class Rows: ObservableObject {
        @Published fileprivate(set) var revision = 0
    }

    let rowsChange = Rows()
    var revision: Int { rowsChange.revision }

    @Published var isOpen: Bool {
        didSet {
            guard isOpen != oldValue else { return }
            Self.defaults.set(isOpen, forKey: "tabSidebarOpen")
            updatePolling() // NEW
        }
    }

    /// The side bar's width in every window: a fixed column the user drags between 260 and 400 pt. The split view it
    /// replaced saved its width as `tabSidebarWidth`, often a narrow 220; that one isn't carried over.
    @Published var width: CGFloat {
        didSet { Self.defaults.set(Double(width), forKey: "sidebarWidth") }
    }

    /// NEW: what the 1.5 s poll finds for a tab.
    struct Live: Equatable {
        var branch: String?
        var command: String?
        /// Split panes in the tab: a change redraws the row.
        var panes = 1
    }

    private(set) var live: [ObjectIdentifier: Live] = [:]   // NEW
    private var book = TabStatusBook()                       // NEW
    private var pollTimer: Timer?                            // NEW
    private var bellObserver: NSObjectProtocol?              // NEW
    private var mainWindowObservers: [NSObjectProtocol] = []

    private var windowTokens: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var groupTokens: [ObjectIdentifier: [NSKeyValueObservation]] = [:]
    /// Groups already asked to hide their bar since their tabs last changed. On macOS 26+ the group can go on
    /// reporting a visible bar after `toggleTabBar`, and each toggle announces `isTabBarVisible` again: asking once
    /// keeps that from looping on the main thread (the collapsed accessory row is what hides it there).
    private var hiddenGroups: Set<ObjectIdentifier> = []
    /// A `refresh` waiting for the next main-queue turn (`refreshSoon`), and whether it should also hide the native
    /// tab bar. Titles change on every prompt and every frame of a TUI's spinner: they share one redraw.
    private var refreshPending = false
    private var tabBarPending = false
    private var tabBarCheckPending = false
    private var activeObservers: [NSObjectProtocol] = []
    /// A group repair is moving tabs: its moves' refreshes don't start another.
    private var repairing = false

    private init() {
        isOpen = Self.defaults.object(forKey: "tabSidebarOpen") as? Bool ?? true
        width = CGFloat(TabSidebarLayout.clamp(
            Self.defaults.object(forKey: "sidebarWidth") as? Double ?? TabSidebarLayout.defaultWidth))
        // NEW: a bell ringing or clearing in any tab.
        bellObserver = NotificationCenter.default.addObserver(
            forName: .terminalWindowBellDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshSoon(tabBar: false) } }
        // AppKit brings the native tab bar back when a tab becomes main (a new tab, Home, an editor tab).
        mainWindowObservers = [NSWindow.didBecomeMainNotification, NSWindow.didBecomeKeyNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated {
                    self?.hideNativeTabBarSoon()
                    if name == NSWindow.didBecomeKeyNotification, let window { self?.frontChanged(window) }
                }
            }
        }
        // The poll slows down while another app is in front.
        activeObservers = [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification].map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePolling() }
            }
        }
        updatePolling()
    }

    // MARK: Rows

    /// The tab kind a Home tab registers under (`GlanceTabController.tabKind`).
    static let homeKind = HomeTabs.kind

    /// Posted (object: the window asking, or nil) when Home is wanted and the window's tab group has none to select:
    /// the host opens one.
    static let showHomeNotification = Notification.Name("dev.glance.Terminal.showHome")

    /// The rows of `window`'s tab group, in tab order, a Home tab included (`kind == .home`: the sidebar pins that one
    /// above its list instead of listing it).
    func rows(for window: NSWindow?) -> [TabRow] {
        guard let window else { return [] }
        let windows = window.tabGroup?.windows ?? [window]
        let selected = window.tabGroup?.selectedWindow ?? window
        let now = Date()
        return windows.map { tab in
            let folderPath = (tab.windowController as? GlancePaneOwner)?.glanceDirectory
            let isSelected = tab === selected
            let info = live[ObjectIdentifier(tab)]
            return TabRow(
                window: tab,
                icon: Self.icon(for: tab),
                title: tab.title.isEmpty ? "Terminal" : ChannelLaunch.hidingFlag(in: tab.title),
                folder: FolderLabel.name(forPath: folderPath),
                branch: info?.branch,
                command: info?.command,
                claude: book.status(forTabFolder: folderPath, at: now),
                bell: !isSelected && ((tab.windowController as? BaseTerminalController)?.bell == true),
                panes: Self.paneCount(of: tab),
                isSelected: isSelected,
                kind: Self.kind(for: tab),
                studioIcon: Self.studioIcon(for: tab))
        }
    }

    /// How many terminals `window`'s tab shows (split panes).
    private static func paneCount(of window: NSWindow) -> Int {
        max(1, (window.windowController as? BaseTerminalController)?.surfaceTree.root?.leaves().count ?? 1)
    }

    /// The Home tab of `window`'s tab group, if it has one.
    func homeRow(for window: NSWindow?) -> TabRow? {
        rows(for: window).first { $0.kind == .home }
    }

    /// What `window`'s tab holds.
    static func kind(for window: NSWindow) -> TabRow.Kind {
        guard let tab = window.windowController as? GlanceTabController else { return .terminal }
        switch tab.tabKind {
        case homeKind: return .home
        case EditorKind.razor.rawValue, EditorKind.studio.rawValue: return .editor
        case EditorStartTab.kind: return .editor
        // Browser tabs, dev servers included, are listed by the Browser side bar only.
        case BrowserTabController.kind: return .chat
        default: return .other
        }
    }

    static func icon(for window: NSWindow) -> String {
        guard let tab = window.windowController as? GlanceTabController else { return "terminal" }
        switch tab.tabKind {
        case EditorKind.razor.rawValue: return EditorKind.razor.symbol
        case EditorKind.studio.rawValue: return EditorKind.studio.symbol
        case EditorStartTab.kind: return "chevron.left.forwardslash.chevron.right"
        case homeKind: return "house.fill"
        case PullRequestWindowController.kind: return "arrow.triangle.pull"
        case ReviewInboxWindowController.kind: return "text.bubble"
        case NewPullRequestWindowController.kind: return "plus.circle"
        case SettingsTabController.kind: return "gearshape"
        case BrowserTabController.kind: return "globe"
        case JournalTabController.kind: return "book.closed"
        case MeetingsTabController.kind: return "mic"
        case UsageTabController.kind: return "chart.bar"
        case NotificationsTabController.kind: return "bell"
        case CapturesTabController.kind: return "note.text"
        case ModsTabController.kind: return "puzzlepiece.extension"
        case AutomationsLibraryTabController.kind(agents: false): return "bolt"
        case AutomationsLibraryTabController.kind(agents: true): return "cpu"
        default: return "square.grid.2x2"
        }
    }

    /// The canvas icon of `window`'s tab, for the side bar's tile.
    static func studioIcon(for window: NSWindow) -> StudioIcons.Name {
        guard let tab = window.windowController as? GlanceTabController else { return .terminal }
        switch tab.tabKind {
        case homeKind: return .home
        case EditorKind.razor.rawValue, EditorKind.studio.rawValue, EditorStartTab.kind: return .editor
        case PullRequestWindowController.kind: return .pullRequest
        case ReviewInboxWindowController.kind: return .chats
        case NewPullRequestWindowController.kind: return .pullRequest
        case SettingsTabController.kind: return .settings
        case BrowserTabController.kind: return .globe
        case JournalTabController.kind: return .journal
        case MeetingsTabController.kind: return .mic
        case UsageTabController.kind: return .chart
        case NotificationsTabController.kind: return .bell
        case CapturesTabController.kind: return .notes
        case ModsTabController.kind: return .puzzle
        case AutomationsLibraryTabController.kind(agents: false): return .automations
        case AutomationsLibraryTabController.kind(agents: true): return .agents
        default: return .file
        }
    }

    // MARK: Claude (NEW)

    /// A Claude session in `cwd` sent a prompt or finished a turn. `focusedFolder` is the folder being looked at, or
    /// nil when Glance Studio isn't in front.
    func claudeTurn(_ kind: TurnEvent.Kind, cwd: String?, focusedFolder: String?) {
        book.turn(kind, cwd: cwd, focusedFolder: focusedFolder, at: Date())
        rowsChange.revision &+= 1
    }

    /// The user is looking at a tab in `folder`: a finished turn there is seen.
    func visit(folder: String?) {
        book.visited(folder: folder)
        rowsChange.revision &+= 1
    }

    // MARK: Polling (NEW)

    private func updatePolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        guard isOpen else { return }
        // Every 1.5 s while Glance Studio is in front, every 5 s behind another app (a Claude turn there can still
        // change the command chip in a window that's in view).
        let active = NSApp?.isActive ?? true
        let timer = Timer.scheduledTimer(withTimeInterval: active ? 1.5 : 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = active ? 0.3 : 1.5
        pollTimer = timer
        poll()
    }

    private struct Probe: Sendable {
        let id: ObjectIdentifier
        let folder: String?
        let pid: Int?
        let panes: Int
    }

    /// Gathers each tab's folder and foreground process on the main thread, then looks up the git branch and the
    /// command on a background queue and applies the result only if something changed.
    private func poll() {
        let probes = NSApp.windows.compactMap { window -> Probe? in
            guard let owner = window.windowController as? GlancePaneOwner else { return nil }
            let pid = (owner as? BaseTerminalController)?.focusedSurface?.surfaceModel?.foregroundPID
            return Probe(id: ObjectIdentifier(window), folder: owner.glanceDirectory, pid: pid, panes: Self.paneCount(of: window))
        }
        DispatchQueue.global(qos: .utility).async { [probes] in
            var result: [ObjectIdentifier: Live] = [:]
            for probe in probes {
                let branch = probe.folder.flatMap { GitHead.branch(inFolder: $0) }
                let command = probe.pid.flatMap { ProcessArguments.read(pid: $0) }
                    .flatMap { CommandName.chip(executable: $0.executable, arguments: $0.arguments) }
                result[probe.id] = Live(branch: branch, command: command, panes: probe.panes)
            }
            DispatchQueue.main.async { [result] in
                MainActor.assumeIsolated { [weak self] in
                    guard let self, self.live != result else { return }
                    self.live = result
                    self.rowsChange.revision &+= 1
                }
            }
        }
    }

    // MARK: Watching

    /// Starts following a window, its siblings' titles and its tab group. Safe to call again.
    func watch(_ window: NSWindow) {
        follow(window.tabGroup)
        watchTitles(of: window.tabGroup?.windows ?? [window])
        refresh()
    }

    private func follow(_ group: NSWindowTabGroup?) {
        guard let group, groupTokens[ObjectIdentifier(group)] == nil else { return }
        groupTokens[ObjectIdentifier(group)] = [
            group.observe(\.windows) { [weak self] _, _ in Task { @MainActor in self?.groupChanged() } },
            group.observe(\.selectedWindow) { [weak self] group, _ in
                let selected = group.selectedWindow
                Task { @MainActor in
                    self?.refreshSoon()
                    if let selected { self?.frontChanged(selected) }
                }
            },
            group.observe(\.isTabBarVisible) { [weak self] _, _ in Task { @MainActor in self?.refreshSoon() } },
        ]
    }

    private func groupChanged() {
        hiddenGroups.removeAll() // a tab joining or leaving can bring the bar back
        for window in NSApp.windows { watchTitles(of: window.tabGroup?.windows ?? []) }
        refresh()
        hideNativeTabBarSoon()
    }

    private func watchTitles(of windows: [NSWindow]) {
        for window in windows where windowTokens[ObjectIdentifier(window)] == nil {
            windowTokens[ObjectIdentifier(window)] = window.observe(\.title) { [weak self] _, _ in
                Task { @MainActor in self?.refreshSoon(tabBar: false) }
            }
        }
    }

    /// `refresh` on the next main-queue turn, once however many changes ask for it before then. `tabBar: false` (a
    /// title, a bell) only redraws the rows: the native tab bar can't have come back.
    func refreshSoon(tabBar: Bool = true) {
        tabBarPending = tabBarPending || tabBar
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let tabBar = self.tabBarPending
                self.refreshPending = false
                self.tabBarPending = false
                self.refresh(tabBar: tabBar)
            }
        }
    }

    func refresh(tabBar: Bool = true) {
        let liveWindows = Set(NSApp.windows.map { ObjectIdentifier($0) })
        let liveGroups = Set(NSApp.windows.compactMap { $0.tabGroup }.map { ObjectIdentifier($0) })
        windowTokens = windowTokens.filter { liveWindows.contains($0.key) }
        groupTokens = groupTokens.filter { liveGroups.contains($0.key) }
        hiddenGroups.formIntersection(liveGroups)
        TabGroups.shared.keep(only: NSApp.windows) // closed tabs leave their groups
        rowsChange.revision &+= 1
        TabRestore.saveSoon() // GLANCE: the open tabs, for the next launch
        if tabBar { applyNativeTabBar() }
        if tabBar { repairGroups() }
    }

    // MARK: The native tab bar

    /// Hides the native tab bar in every tab group, sidebar open or not: tabs live in the sidebar, and the top bar
    /// leaves no room for a second row. A group with a single tab has no bar to manage.
    func applyNativeTabBar() {
        var seen = Set<ObjectIdentifier>()
        for window in NSApp.windows {
            guard let group = window.tabGroup, seen.insert(ObjectIdentifier(group)).inserted else { continue }
            follow(group) // a group first seen before its window had one isn't followed yet
            if group.windows.count > 1, group.isTabBarVisible, hiddenGroups.insert(ObjectIdentifier(group)).inserted {
                (group.selectedWindow ?? window).toggleTabBar(nil)
            }
        }
        // AppKit moves the bar to whichever tab becomes main: collapse its row wherever it has gone.
        for case let window as TerminalWindow in NSApp.windows {
            for accessory in window.titlebarAccessoryViewControllers
            where !accessory.isHidden
                && (accessory.identifier == TerminalWindow.tabBarIdentifier || accessory.view.contains(className: "NSTabBar")) {
                window.hideTabBarAccessory(accessory)
            }
        }
    }

    /// AppKit shows the bar after a tab joins or becomes main, a turn after the change that announced it: check now
    /// and again once it has.
    private func hideNativeTabBarSoon() {
        applyNativeTabBar()
        // A tab switch posts main and key notifications back to back: one follow-up check covers both.
        guard !tabBarCheckPending else { return }
        tabBarCheckPending = true
        DispatchQueue.main.async { [weak self] in
            self?.tabBarCheckPending = false
            self?.applyNativeTabBar()
        }
    }

    // MARK: Strip switching (spec 2026-10-11-strip-switching-design.md)

    /// Per tab group: the tab last in front for each strip item, and the order tabs were in front.
    private var memories: [ObjectIdentifier: StripMemory<ObjectIdentifier>] = [:]

    private static func memoryKey(_ window: NSWindow) -> ObjectIdentifier {
        if let group = window.tabGroup { return ObjectIdentifier(group) }
        return ObjectIdentifier(window)
    }

    /// The Glance kind of `window`'s tab (`GlanceTabController.tabKind`), nil for a terminal tab.
    static func tabKind(of window: NSWindow) -> String? {
        (window.windowController as? GlanceTabController)?.tabKind
    }

    /// `window` came to the front of its tab group: remember it for its strip item (Home only in the order), and
    /// show that item's side bar. Only Studio's tab windows count: a palette, sheet or panel turning key doesn't.
    func frontChanged(_ window: NSWindow) {
        guard window is TerminalWindow, (window.tabGroup?.selectedWindow ?? window) === window else { return }
        let kind = Self.tabKind(of: window)
        let mode = SidebarMode.owner(ofTabKind: kind)
        memories[Self.memoryKey(window), default: StripMemory()]
            .recordFront(ObjectIdentifier(window), mode: kind == Self.homeKind ? nil : mode)
        if let mode { SidebarModeModel.shared.follow(mode) }
    }

    /// `window`'s group's memory (empty when nothing has been in front yet).
    func memory(near window: NSWindow) -> StripMemory<ObjectIdentifier> {
        memories[Self.memoryKey(window)] ?? StripMemory()
    }

    /// The tab a click on `mode` goes back to in `window`'s group (spec §1), or nil when it has none open. Home is
    /// never one.
    func lastTab(for mode: SidebarMode, near window: NSWindow) -> NSWindow? {
        let tabs = window.tabGroup?.windows ?? [window]
        let candidates = tabs.filter { tab in
            let kind = Self.tabKind(of: tab)
            return kind != Self.homeKind && SidebarMode.owner(ofTabKind: kind) == mode
        }
        guard let id = memory(near: window).last(for: mode, candidates: candidates.map(ObjectIdentifier.init))
        else { return nil }
        return candidates.first { ObjectIdentifier($0) == id }
    }

    // MARK: Actions

    func select(_ row: TabRow) {
        row.window.tabGroup?.selectedWindow = row.window
        row.window.makeKey()
    }

    /// The sidebar's pinned Home and the top bar's ⌂: the Home tab of `window`'s group, or a new one from the host.
    func showHome(near window: NSWindow?) {
        if let home = homeRow(for: window) {
            select(home)
        } else {
            NotificationCenter.default.post(name: Self.showHomeNotification, object: window)
        }
    }

    /// Closes the tab the way the tab bar would: Ghostty's `closeTab` for terminals (it confirms when something is
    /// running), `performClose` otherwise (an editor tab asks about unsaved changes).
    func close(_ row: TabRow) {
        if let terminal = row.window.windowController as? TerminalController {
            terminal.closeTab(nil)
        } else {
            row.window.performClose(nil)
        }
    }

    func newTab(near window: NSWindow?) {
        let tabs = window?.tabGroup?.windows ?? [window].compactMap { $0 }
        let terminals = tabs.compactMap { $0.windowController as? TerminalController }
        if let terminal = terminals.first(where: { $0.window === window }) ?? terminals.first {
            terminal.newTab(nil)
        } else if let app = NSApp.delegate as? AppDelegate {
            // No terminal in this window (editor, Browser or Home tabs only): the new one joins its tabs rather than
            // opening a window of its own.
            Self.newTerminalTab(app.ghostty, joining: window)
        }
    }

    /// A terminal tab added to `window`'s tabs when none of them is a terminal (Ghostty's newTab needs a terminal
    /// parent). Built as newTab builds one, not with newWindow: that gives the window a native full screen of its
    /// own when `window` is full screen, so the click slid off to a new Space (it looked minimized).
    static func newTerminalTab(_ ghostty: Ghostty.App, joining window: NSWindow?,
                               withBaseConfig config: Ghostty.SurfaceConfiguration? = nil) {
        guard let window else {
            _ = TerminalController.newWindow(ghostty, withBaseConfig: config)
            return
        }
        let controller = TerminalController(ghostty, withBaseConfig: config)
        guard let new = controller.window else { return }
        if window.addTabbedWindowSafely(new, ordered: .above) {
            window.tabGroup?.selectedWindow = new
        }
        controller.showWindowSafely(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Moves a tab the way Ghostty's own "move tab" does: remove it from the group, add it next to its new neighbour.
    /// `offset` counts in `rows`, the rows the caller shows (the sidebar leaves its pinned Home out), so the neighbour
    /// is found among those rows' windows. `select: false` (repairing a group) leaves the selected tab in front.
    func move(_ row: TabRow, toOffset offset: Int, in rows: [TabRow], select: Bool = true) {
        guard let from = rows.firstIndex(where: { $0.id == row.id }),
              let destination = TabOrder.insertionIndex(from: from, toOffset: offset),
              let group = row.window.tabGroup else { return }
        let moved = row.window
        let remaining = rows.map(\.window).filter { $0 !== moved }
        // Rows from before a tab closed or left the group: leave the order alone.
        guard !remaining.isEmpty, remaining.allSatisfy({ $0.tabGroup === group }) else { return }
        let selected = group.selectedWindow
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        group.removeWindow(moved)
        if destination >= remaining.count {
            remaining[remaining.count - 1].addTabbedWindowSafely(moved, ordered: .above)
        } else {
            remaining[destination].addTabbedWindowSafely(moved, ordered: .below)
        }
        if select {
            moved.makeKey()
        } else if let selected {
            group.selectedWindow = selected
        }
        NSAnimationContext.endGrouping()
        (moved.windowController as? TerminalController)?.relabelTabs()
        refresh()
    }

    // MARK: Groups (spec 2026-10-11-tab-groups-design.md)

    /// The terminal rows of `window`'s tab group: what the Terminal side bar lists and groups.
    func terminalRows(for window: NSWindow?) -> [TabRow] {
        rows(for: window).filter { $0.kind == .terminal }
    }

    /// Brings each group's tabs back together in every tab group (a native move or a restore can split one), one move
    /// at a time, leaving the selected tab in front.
    private func repairGroups() {
        let groups = TabGroups.shared
        guard groups.isOn, !repairing else { return }
        repairing = true
        defer { repairing = false }
        var seen = Set<ObjectIdentifier>()
        for window in NSApp.windows {
            guard let tabGroup = window.tabGroup, seen.insert(ObjectIdentifier(tabGroup)).inserted else { continue }
            var rows = terminalRows(for: window)
            for _ in rows.indices {
                guard let fix = TabGroupLayout.repair(rows.map(\.id), membership: groups.membership, groups: groups.groups),
                      let row = rows.first(where: { $0.id == fix.tab }) else { break }
                move(row, toOffset: fix.toOffset, in: rows, select: false)
                rows = terminalRows(for: window)
            }
        }
    }

    /// The row menu's Add to New Group.
    func newGroup(with row: TabRow) {
        TabGroups.shared.newGroup(with: row.window)
    }

    /// Move to Group / Remove from Group: into `group` at its end, or (nil) out of its group to just after it.
    func moveToGroup(_ row: TabRow, _ group: UUID?, in rows: [TabRow]) {
        let groups = TabGroups.shared
        let ids = rows.map(\.id)
        let anchor = group ?? groups.group(of: row.window)
        let offset = anchor.flatMap { TabGroupLayout.joinOffset(group: $0, tabs: ids, membership: groups.membership) }
        groups.assign(row.window, to: group)
        if let offset { move(row, toOffset: offset, in: rows) }
    }

    /// A row let go just below `above` in the Terminal side bar: it joins that section and moves there.
    func drop(_ row: TabRow, below above: TabGroupLayout.Item<ObjectIdentifier>?, in rows: [TabRow]) {
        let groups = TabGroups.shared
        let place = TabGroupLayout.drop(below: above, tabs: rows.map(\.id), membership: groups.membership,
                                        groups: groups.groups)
        if groups.group(of: row.window) != place.group { groups.assign(row.window, to: place.group) }
        move(row, toOffset: place.toOffset, in: rows)
    }

    /// A group header's +: a new terminal tab at the end of the group. Opened from the group's last tab directly, not
    /// through its focused surface, which a tab never clicked into doesn't have; Ghostty may add it at the end of the
    /// window's tabs, so it then moves in beside the group's last one. (⌘T and New Tab open ungrouped tabs.)
    func newTab(inGroup group: UUID, in rows: [TabRow]) {
        guard let last = rows.last(where: { TabGroups.shared.group(of: $0.window) == group }),
              let parent = last.window.windowController as? TerminalController,
              let window = TerminalController.newTab(parent.ghostty, from: last.window)?.window else { return }
        // Where it joins is worked out before it's in the group, so it lands after the group's last tab.
        let offset = TabGroupLayout.joinOffset(group: group, tabs: terminalRows(for: window).map(\.id),
                                               membership: TabGroups.shared.membership)
        TabGroups.shared.assign(window, to: group)
        // The next turn: AppKit has finished adding the tab.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, let offset else { return }
            let rows = self.terminalRows(for: window)
            guard let row = rows.first(where: { $0.window === window }) else { return }
            self.move(row, toOffset: offset, in: rows)
        }
    }

    /// Rename…: Ghostty's tab title prompt, on the tab brought to the front (the sheet needs it on screen).
    func rename(_ row: TabRow) {
        guard let terminal = row.window.windowController as? TerminalController else { return }
        select(row)
        terminal.promptTabTitle()
    }

    func setCollapsed(_ group: UUID, _ collapsed: Bool) {
        TabGroups.shared.setCollapsed(group, collapsed)
    }

    /// Ungroup: the tabs stay where they are, out of any group.
    func ungroup(_ group: UUID, in rows: [TabRow]) {
        let windows = rows.map(\.window).filter { TabGroups.shared.group(of: $0) == group }
        TabGroups.shared.ungroup(group, windows: windows)
    }

    /// Close Group: each tab closes as its close button would (a running command still asks).
    func closeGroup(_ group: UUID, in rows: [TabRow]) {
        for row in rows where TabGroups.shared.group(of: row.window) == group { close(row) }
    }
}
