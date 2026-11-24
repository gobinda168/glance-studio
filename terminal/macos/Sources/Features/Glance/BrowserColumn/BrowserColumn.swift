import AppKit
import GlanceCore

/// Shows and hides a terminal tab's browser column (⌥⌘O, the top-bar globe, the palette, links). Terminal tabs only,
/// only with Feature.browserColumn.
@MainActor
enum BrowserColumn {
    static var isEnabled: Bool { StudioFeatures.shared.isOn(.browserColumn) }

    static func controller(_ window: NSWindow?) -> BaseTerminalController? {
        window?.windowController as? BaseTerminalController
    }

    static func isAvailable(_ window: NSWindow?) -> Bool { isEnabled && controller(window) != nil }

    static func toggle(_ window: NSWindow?) {
        guard isAvailable(window), let c = controller(window) else { return }
        set(!c.browserColumnOpen, in: c)
    }

    static func set(_ open: Bool, in controller: BaseTerminalController) {
        guard controller.browserColumnOpen != open else { return }
        controller.browserColumnOpen = open
        controller.window?.invalidateRestorableState()
        // Closing gives the keyboard back to the terminal; opening, the column's address field takes it (shown()).
        if !open, let surface = controller.focusedSurface { controller.window?.makeFirstResponder(surface) }
    }

    /// A web link opened into the tab's column, which opens if it was closed.
    static func open(_ url: URL, in controller: BaseTerminalController) {
        guard isEnabled else { return }
        controller.browserColumn.open(url)
        set(true, in: controller)
    }

    /// Feature.browserColumn went off: every column closes.
    static func featureSwitchedOff() {
        for c in TerminalController.all where c.browserColumnOpen { set(false, in: c) }
    }
}
