import AppKit
import GlanceCore

/// Open in Editor / Open in Terminal (spec 2026-10-11-strip-switching-design.md §4): between a project's terminal
/// and its editor in this window, reusing the open tab, never making a second.
@MainActor
enum ProjectSwitch {
    enum Direction { case toEditor, toTerminal }

    static func direction(for window: NSWindow?) -> Direction? {
        guard let controller = window?.windowController else { return nil }
        if controller is TerminalController { return .toEditor }
        if controller is any EditorTab { return .toTerminal }
        return nil
    }

    /// The tab's project: an editor's root; a terminal's working directory's git root (else the directory).
    static func project(of window: NSWindow) -> String? {
        if let editor = window.windowController as? any EditorTab { return editor.root }
        guard let folder = (window.windowController as? GlancePaneOwner)?.glanceDirectory, !folder.isEmpty
        else { return nil }
        return ProjectRoot.find(from: folder)
    }

    static func toggle(_ window: NSWindow?) {
        guard let window else { return }
        switch direction(for: window) {
        case .toEditor: openInEditor(from: window)
        case .toTerminal: openInTerminal(from: window)
        case nil: break
        }
    }

    static func openInEditor(from window: NSWindow) {
        let home = NSHomeDirectory()
        guard let project = project(of: window), !TabSwitch.isProjectless(project, home: home) else {
            _ = EditorStartTab.open(from: window)
            return
        }
        switch TabSwitch.editor(for: project, editors: editors(near: window), home: home) {
        case .reuse(let id):
            select(id, near: window)
        case .create:
            EditorTabs.open(EditorTabs.preferredKind, root: SessionMatch.normalize(project, home: home), from: window)
            HomeTabs.recordProject(from: project)
        }
    }

    static func openInTerminal(from window: NSWindow) {
        guard let project = project(of: window) else { return }
        let target = TabSwitch.terminal(for: project, terminals: terminals(near: window),
                                        memory: TabSidebarModel.shared.memory(near: window), home: NSHomeDirectory())
        switch target {
        case .reuse(let id): select(id, near: window)
        case .create: EditorBridgeActions.openTerminalTab(cwd: project, near: window)
        }
    }

    /// What a click will do, for the top bar item's help text.
    static func help(for window: NSWindow?) -> String {
        guard let window, let project = project(of: window) else { return "" }
        let name = EditorFolderPicker.name(project)
        let home = NSHomeDirectory()
        switch direction(for: window) {
        case .toEditor:
            if TabSwitch.isProjectless(project, home: home) { return "Choose a project to open in the editor (⌥⌘E)" }
            if case .reuse = TabSwitch.editor(for: project, editors: editors(near: window), home: home) {
                return "Go to the \(name) editor tab (⌥⌘E)"
            }
            return "Open \(name) in a new editor tab (⌥⌘E)"
        case .toTerminal:
            let target = TabSwitch.terminal(for: project, terminals: terminals(near: window),
                                            memory: TabSidebarModel.shared.memory(near: window), home: home)
            if case .reuse = target { return "Go to the last terminal in \(name) (⌥⌘E)" }
            return "Open a terminal in \(name) (⌥⌘E)"
        case nil:
            return ""
        }
    }

    // MARK: The window's tabs

    private static func editors(near window: NSWindow) -> [(tab: ObjectIdentifier, root: String)] {
        EditorTabs.all().compactMap { tab in
            guard let tabWindow = tab.window, tabWindow.tabGroup === window.tabGroup else { return nil }
            return (ObjectIdentifier(tabWindow), tab.root)
        }
    }

    private static func terminals(near window: NSWindow) -> [(tab: ObjectIdentifier, project: String)] {
        (window.tabGroup?.windows ?? [window]).compactMap { tab in
            guard let terminal = tab.windowController as? TerminalController,
                  let folder = terminal.glanceDirectory, !folder.isEmpty else { return nil }
            return (ObjectIdentifier(tab), ProjectRoot.find(from: folder))
        }
    }

    private static func select(_ id: ObjectIdentifier, near window: NSWindow) {
        guard let tab = (window.tabGroup?.windows ?? [window]).first(where: { ObjectIdentifier($0) == id }) else { return }
        tab.tabGroup?.selectedWindow = tab
        tab.makeKey() // ordering it front too sends a full-screen window off its Space (see StripSwitch)
    }
}

/// View › Open in Editor / Open in Terminal (⌥⌘E): its title follows the key tab.
@MainActor
final class ProjectSwitchMenu: NSObject, NSMenuItemValidation {
    static let shared = ProjectSwitchMenu()

    func install(in view: NSMenu) {
        let item = NSMenuItem(title: "Open in Editor", action: #selector(toggle), keyEquivalent: "e")
        item.keyEquivalentModifierMask = [.command, .option]
        item.target = self
        view.addItem(item)
    }

    @objc func toggle() { ProjectSwitch.toggle(NSApp.keyWindow) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch ProjectSwitch.direction(for: NSApp.keyWindow) {
        case .toEditor: item.title = "Open in Editor"; return true
        case .toTerminal: item.title = "Open in Terminal"; return true
        case nil: item.title = "Open in Editor"; return false
        }
    }
}
