import AppKit

/// View › Show Browser Column / Hide Browser Column (⌥⌘O).
@MainActor
final class BrowserColumnMenu: NSObject, NSMenuItemValidation {
    static let shared = BrowserColumnMenu()

    func install(in view: NSMenu) {
        let item = NSMenuItem(title: "Show Browser Column", action: #selector(toggle), keyEquivalent: "o")
        item.keyEquivalentModifierMask = [.command, .option]
        item.target = self
        view.addItem(item)
    }

    @objc func toggle() { BrowserColumn.toggle(NSApp.keyWindow) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.isHidden = !BrowserColumn.isEnabled
        let open = BrowserColumn.controller(NSApp.keyWindow)?.browserColumnOpen == true
        item.title = open ? "Hide Browser Column" : "Show Browser Column"
        return BrowserColumn.isAvailable(NSApp.keyWindow)
    }
}
