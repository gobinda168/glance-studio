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

    @discardableResult
    static func open<Controller: NSWindowController & GlanceTabController>(
        kind: String, key: String, from parent: NSWindow?, reuse: Bool = true, make: () -> Controller
    ) -> Controller? {
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
