import AppKit
import GlanceCore
import GlanceKit

/// Opening and finding the Home tab, the terminal it goes back to, and what its page shows (spec
/// 2026-10-07-home-tab-design.md).
@MainActor
enum HomeTabs {
    static let kind = "home"

    /// Home opens once per launch, unless turned off.
    private static var launchPending = Prefs.showHomeAtLaunch
    private static var lastRecorded: (root: String, at: Date)?
    /// Each project's changed-file count and when it was counted: `git status` runs at most every few seconds, and
    /// never twice at once for a project (a big repository can take a while).
    private static var changeCounts: [String: (count: Int?, at: Date)] = [:]
    private static var counting: Set<String> = []

    // MARK: Opening

    /// A window became key. The first terminal window to do so after launch gets Home, a moment later: Ghostty
    /// finishes setting a new or restored window up (its tab group, its position) on later turns of the run loop.
    static func windowBecameKey(_ window: NSWindow) {
        guard launchPending, window.windowController is TerminalController else { return }
        launchPending = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                // A restored session may have brought another of its windows to the front by now.
                let key = NSApp.keyWindow.flatMap { $0.windowController is TerminalController ? $0 : nil }
                let front = key ?? window
                guard front.isVisible, front.tabbingMode != .disallowed else { return }
                if let style = (front.windowController as? TerminalController)?.fullscreenStyle,
                   style.isFullscreen, !style.supportsTabs { return }
                show(in: front)
            }
        }
    }

    /// File → Home and the sidebar's Home entry: the Home tab of `window`'s tab group, selected, else a new one at the
    /// end of the group (terminal tabs keep their ⌘1–⌘9).
    @discardableResult
    static func show(in window: NSWindow?) -> HomeWindowController? {
        let parent = tabWindow(window)
        return GlanceTabHost.open(kind: kind, key: kind, from: parent?.tabGroup?.windows.last ?? parent) {
            HomeWindowController()
        }
    }

    /// A window whose tab group Home may join: a terminal or another Glance tab (`window`, else the main window, else
    /// the terminal used last). Never the quick terminal or a panel like Settings.
    private static func tabWindow(_ window: NSWindow?) -> NSWindow? {
        [window, NSApp.mainWindow, TerminalController.preferredParent?.window].compactMap { $0 }.first {
            $0.windowController is TerminalController || $0.windowController is GlanceTabController
        }
    }

    // MARK: The terminal

    /// The terminal tab Home goes back to: the one of its tab group used last, else the group's first.
    static func terminal(near window: NSWindow?) -> TerminalController? {
        let terminals = (window?.tabGroup?.windows ?? [window].compactMap { $0 })
            .compactMap { $0.windowController as? TerminalController }
        if let last = TerminalController.lastMain, terminals.contains(where: { $0 === last }) { return last }
        return terminals.first
    }

    /// Return and Esc on the page: that terminal tab, its split focused. A group without one gets a new one.
    static func focusTerminal(near window: NSWindow?) {
        guard let terminal = terminal(near: window), let tab = terminal.window else {
            newTerminal(near: window)
            return
        }
        tab.tabGroup?.selectedWindow = tab
        tab.makeKey() // ordering it front too sends a full-screen window off its Space (see StripSwitch)
        if let surface = terminal.focusedSurface { Ghostty.moveFocus(to: surface) }
    }

    /// A new terminal tab beside that terminal, in its folder, as the sidebar's New Terminal Tab makes it; without
    /// one, a tab in the home folder.
    static func newTerminal(near window: NSWindow?) {
        if let terminal = terminal(near: window) {
            TabSidebarModel.shared.newTab(near: terminal.window)
        } else {
            EditorBridgeActions.openTerminalTab(cwd: NSHomeDirectory(), near: window)
        }
    }

    /// A recent project, in a new terminal tab or the editor. False when its folder is gone.
    static func open(project path: String, in target: HomeAction.Target, near window: NSWindow?) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        switch target {
        case .terminal: EditorBridgeActions.openTerminalTab(cwd: path, near: window)
        case .editor: EditorTabs.open(EditorTabs.preferredKind, root: ProjectRoot.find(from: path), from: window)
        }
        recordProject(from: path)
        return true
    }

    // MARK: What the page shows

    /// A folder took focus: its project moves to the front of Home's Recent list. The same project again within a
    /// minute isn't written again.
    static func recordProject(from folder: String?) {
        guard let folder, !folder.isEmpty else { return }
        let root = ProjectRoot.find(from: folder)
        let now = Date()
        if let last = lastRecorded, last.root == root, now.timeIntervalSince(last.at) < 60 { return }
        lastRecorded = (root, now)
        var recent = Prefs.recentProjects
        recent.record(root, at: now)
        Prefs.recentProjects = recent
    }

    /// Claude's status in the folder Home follows: Home's own sidebar row (it has the terminal's folder), else the
    /// terminal's row.
    static func claudeStatus(near window: NSWindow?) -> TabStatusBook.Status {
        guard let window else { return .idle }
        let rows = TabSidebarModel.shared.rows(for: window)
        let terminal = terminal(near: window)?.window
        return (rows.first { $0.window === window } ?? rows.first { $0.window === terminal })?.claude ?? .idle
    }

    /// What the page shows from the disk, read off the main thread: the project of `directory` with its branch and
    /// its last known changed-file count, and the recent projects still there with their branches. Projects found gone
    /// leave the list. A count older than a few seconds is redone on the side, then `recounted` is called.
    static func readDisk(
        directory: String?, now: Date, recounted: @escaping @MainActor () -> Void,
        completion: @escaping @MainActor (HomeState.Folder?, [HomeState.Project]) -> Void
    ) {
        let root = directory.map { ProjectRoot.find(from: $0) }
        if let root { recountChanges(root, now: now, then: recounted) }
        let count = root.flatMap { changeCounts[$0]?.count }
        let recent = Prefs.recentProjects.entries
        DispatchQueue.global(qos: .utility).async {
            let folder = root.map { HomeState.Folder(path: $0, branch: GitHead.branch(inFolder: $0), changes: count) }
            var gone: Set<String> = []
            var projects: [HomeState.Project] = []
            for entry in recent {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    gone.insert(entry.path)
                    continue
                }
                if projects.count < HomeState.recentLimit {
                    projects.append(HomeState.Project(entry, branch: GitHead.branch(inFolder: entry.path), now: now))
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if !gone.isEmpty {
                        var list = Prefs.recentProjects
                        list.prune { !gone.contains($0) }
                        Prefs.recentProjects = list
                    }
                    completion(folder, projects)
                }
            }
        }
    }

    /// Counts the project's changed files with `git status` off the main thread, unless a count is recent or under
    /// way. Never in the home folder or /: a dotfiles repository there would have git walk the whole disk.
    private static func recountChanges(_ root: String, now: Date, then done: @escaping @MainActor () -> Void) {
        let home = SessionMatch.normalize(NSHomeDirectory(), home: NSHomeDirectory())
        let fresh = changeCounts[root].map { now.timeIntervalSince($0.at) < 5 } ?? false
        guard root != "/", root != home, !fresh, !counting.contains(root) else { return }
        counting.insert(root)
        DispatchQueue.global(qos: .utility).async {
            let count = GitChanges.status(root: root)?.count
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    counting.remove(root)
                    changeCounts[root] = (count, Date())
                    done()
                }
            }
        }
    }
}
