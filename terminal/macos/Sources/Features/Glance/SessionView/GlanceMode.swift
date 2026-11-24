import AppKit
import SwiftUI
import GlanceCore

/// Terminal ⇄ Glance for the key tab (⌥⌘G, the top-bar switch). Only terminal tabs, only with Feature.commandCenter.
@MainActor
enum GlanceMode {
    static func controller(_ window: NSWindow?) -> BaseTerminalController? {
        window?.windowController as? BaseTerminalController
    }

    static func isAvailable(_ window: NSWindow?) -> Bool {
        StudioFeatures.shared.isOn(.commandCenter) && controller(window) != nil
    }

    static func toggle(_ window: NSWindow?) {
        guard isAvailable(window), let c = controller(window) else { return }
        set(!c.glanceMode, in: c)
    }

    static func set(_ on: Bool, in controller: BaseTerminalController) {
        guard controller.glanceMode != on else { return }
        controller.glanceMode = on
        controller.window?.invalidateRestorableState()
        // Leaving Glance gives the keyboard back to the terminal; entering it, the composer takes it (ComposerView).
        if !on, let surface = controller.focusedSurface { controller.window?.makeFirstResponder(surface) }
    }

    /// Feature.commandCenter went off: every tab shows its terminal again.
    static func commandCenterSwitchedOff() {
        for c in TerminalController.all where c.glanceMode { set(false, in: c) }
    }
}

/// View › Show Hyperviz View / Show Terminal (⌥⌘G).
@MainActor
final class GlanceModeMenu: NSObject, NSMenuItemValidation {
    static let shared = GlanceModeMenu()

    func install(in view: NSMenu) {
        let item = NSMenuItem(title: "Show Hyperviz View", action: #selector(toggle), keyEquivalent: "g")
        item.keyEquivalentModifierMask = [.command, .option]
        item.target = self
        view.addItem(item)
    }

    @objc func toggle() { GlanceMode.toggle(NSApp.keyWindow) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.isHidden = !StudioFeatures.shared.isOn(.commandCenter)
        let on = GlanceMode.controller(NSApp.keyWindow)?.glanceMode == true
        item.title = on ? "Show Terminal" : "Show Hyperviz View"
        return GlanceMode.isAvailable(NSApp.keyWindow)
    }
}
