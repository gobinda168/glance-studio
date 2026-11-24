import AppKit
import Combine
import GlanceCore

/// "New Claude session in a new worktree" (spec §3): asks for the task, makes `../<repo>-<task>` on a new branch
/// from the repository's default branch, and opens a tab there with Claude running.
@MainActor
enum NewWorktreeFlow {
    /// Finds the repository of `window`'s folder (git runs off the main thread), then asks.
    static func start(from window: NSWindow?) {
        Task { @MainActor in
            ask(current: await repository(of: window), near: window)
        }
    }

    /// The repository of `window`'s folder, found off the main thread; nil when it has none.
    static func repository(of window: NSWindow?) async -> RepoLocation? {
        guard let directory = (window?.windowController as? GlancePaneOwner)?.glanceDirectory else { return nil }
        return await Task.detached(priority: .userInitiated) { RepoLocation.find(cwd: directory) }.value
    }

    /// The main worktree of `location`'s repository: the folder holding its common `.git`, else its own worktree.
    static func mainRoot(of location: RepoLocation) -> String {
        location.commonDir.hasSuffix("/.git")
            ? String(location.commonDir.dropLast("/.git".count)) : location.worktree
    }

    /// The repositories to choose from: those the side bar lists, and the window's own when it isn't one of them, with
    /// the index to start on. With none, says so (`emptyTitle`) and returns nil.
    static func choices(current: RepoLocation?, emptyTitle: String) -> (roots: [String], selected: Int?)? {
        var roots = WorktreesModel.shared.repos.map(\.main)
        var selected = current.flatMap { location in
            WorktreesModel.shared.repos.firstIndex { $0.repo == location.commonDir }
        }
        if let current, selected == nil {
            roots.append(mainRoot(of: current))
            selected = roots.count - 1
        }
        guard !roots.isEmpty else {
            report(emptyTitle, "Open a terminal in a git repository first.")
            return nil
        }
        return (roots, selected)
    }

    /// Makes the worktree for `task` in `root` (`git worktree add` checks the branch out: off the main thread), then
    /// hands its folder to `open`. A failure of either is reported; `open` returns false when it couldn't.
    static func create(in root: String, task: String, open: @escaping (String) -> Bool) {
        Task { @MainActor in
            let made = await Task.detached(priority: .userInitiated) {
                WorktreeActions.create(repoRoot: root, task: task, from: nil)
            }.value
            switch made {
            case .success(let made):
                let opened = open(made.path)
                WorktreesModel.shared.refresh()
                if !opened {
                    report("Couldn't start the session", "The worktree was made at \(made.path), but a tab wouldn't open in it.")
                }
            case .failure(let failure):
                report("Couldn't create the worktree", failure.message)
            }
        }
    }

    /// A modal message.
    static func report(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }

    private static func ask(current: RepoLocation?, near window: NSWindow?) {
        guard let (roots, selected) = choices(current: current, emptyTitle: "No repository to make a worktree in") else { return }
        let alert = NSAlert()
        alert.messageText = "New Claude session in a new worktree"
        alert.informativeText = "What's the task? It names the folder and the branch."
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))
        stack.orientation = .vertical
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "Fix the shell tests"
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        picker.addItems(withTitles: roots)
        if let selected { picker.selectItem(at: selected) }
        stack.addArrangedSubview(field)
        stack.addArrangedSubview(picker)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, let root = picker.titleOfSelectedItem else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        create(in: root, task: name) { path in
            WorktreeTerminal.open(in: path, claude: true, near: window)
            return true
        }
    }
}

/// File › New Session in New Worktree… (⌥⌘N; ⇧⌘N is Notifications), shown while Worktrees is on. With Command on it is
/// New Session…, which asks for the project and whether to make a worktree.
@MainActor
final class NewWorktreeMenu: NSObject, NSMenuItemValidation {
    static let shared = NewWorktreeMenu()

    private var watch: AnyCancellable?

    func install(in menu: NSMenu, at index: Int) {
        let item = NSMenuItem(title: "New Session in New Worktree…", action: #selector(start), keyEquivalent: "n")
        item.keyEquivalentModifierMask = [.command, .option]
        item.target = self
        menu.insertItem(item, at: min(index, menu.items.count))
        watch = StudioFeatures.shared.$enabled.sink { [weak item] enabled in
            item?.isHidden = !(enabled.contains(.worktrees) || enabled.contains(.commandCenter))
            item?.title = enabled.contains(.commandCenter) ? "New Session…" : "New Session in New Worktree…"
        }
    }

    @objc func start() {
        if StudioFeatures.shared.isOn(.commandCenter) {
            NewSessionFlow.start(from: NSApp.keyWindow)
        } else {
            NewWorktreeFlow.start(from: NSApp.keyWindow)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        StudioFeatures.shared.isOn(.worktrees) || StudioFeatures.shared.isOn(.commandCenter)
    }
}
