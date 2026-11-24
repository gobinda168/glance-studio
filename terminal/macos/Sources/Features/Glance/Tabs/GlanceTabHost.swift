import AppKit

/// What a non-terminal tab says about itself so the host can find it again.
@MainActor
protocol GlanceTabController: AnyObject {
    var tabKind: String { get }
    var tabKey: String { get }
    var window: NSWindow? { get }
}

/// Opens non-terminal tabs (the editor, later an automation agent): one tab per kind and key per tab group, unless the
/// caller asks for a new one.
@MainActor
enum GlanceTabHost {
    private static var controllers: [any GlanceTabController] = []
    /// While the launch brings the last run's tabs back (`TabRestore`): a tab is made but neither shown nor selected,
    /// and the restore puts it in its place itself, so the window in front never changes until the restore is done.
    static var restoring = false

    /// The window a new tab joins: `window` if a tab can join it, else the main window, else the terminal used last. Never
    /// the quick terminal or a panel like Settings, so a tab asked for from one of those, or from nothing, still lands
    /// inside Studio's window instead of opening one of its own.
    static func tabWindow(_ window: NSWindow?) -> NSWindow? {
        [window, NSApp.mainWindow, TerminalController.preferredParent?.window].compactMap { $0 }.first {
            $0.windowController is TerminalController || $0.windowController is GlanceTabController
        }
    }

    @discardableResult
    static func open<Controller: NSWindowController & GlanceTabController>(
        kind: String, key: String, from parent: NSWindow?, reuse: Bool = true, make: () -> Controller
    ) -> Controller? {
        // The restore picks each tab's place itself, and with no window yet there is nothing to join.
        let parent = restoring ? parent : tabWindow(parent)
        if reuse, let existing = controllers.first(where: {
            $0.tabKind == kind && $0.tabKey == key && parent?.tabGroup != nil && $0.window?.tabGroup === parent?.tabGroup
        }) {
            if restoring { return existing as? Controller }
            existing.window?.tabGroup?.selectedWindow = existing.window
            (existing as? NSWindowController)?.showWindowSafely(nil)
            return existing as? Controller
        }
        let controller = make()
        controllers.append(controller)
        guard !restoring, let window = controller.window else { return controller }
        if let parent, parent.tabbingMode != .disallowed, parent.addTabbedWindowSafely(window, ordered: .above) {
            parent.tabGroup?.selectedWindow = window
        }
        controller.showWindowSafely(nil)
        NSApp.activate(ignoringOtherApps: true)
        return controller
    }

    /// The open tabs of one kind, in every window.
    static func controllers(kind: String) -> [any GlanceTabController] {
        controllers.filter { $0.tabKind == kind }
    }

    static func closed(_ controller: any GlanceTabController) {
        controllers.removeAll { $0 === controller }
    }
}
