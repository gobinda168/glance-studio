import AppKit

/// The Browser's keys (spec 2026-10-10-browser-design.md, "Surface"): while a Browser tab is in front they come
/// ahead of the menus: ⌘L address, ⌘T new tab, ⌘⇧T reopen closed, ⌘[ ⌘] back and forward, ⌘R reload, ⌘F find,
/// ⌘+ ⌘− ⌘0 zoom. Everywhere else Studio's keys keep their meaning.
@MainActor
enum BrowserKeys {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event) ? nil : event }
        }
    }

    /// True when `event` was a Browser key in a Browser tab, and was handled.
    static func handle(_ event: NSEvent) -> Bool {
        guard let window = NSApp.keyWindow, let tab = window.windowController as? BrowserTabController else {
            return false
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else { return false }
        let shift = flags.contains(.shift)
        switch (event.charactersIgnoringModifiers?.lowercased() ?? "", shift) {
        case ("l", false): tab.addressFocus += 1
        case ("t", false): BrowserTabController.open(url: nil, from: window)
        case ("t", true): BrowserTabController.reopenClosed(from: window)
        case ("[", false): tab.back()
        case ("]", false): tab.forward()
        case ("r", false): tab.webView?.reload()
        case ("f", false):
            guard tab.webView != nil else { return false }
            tab.findVisible = true
            tab.findFocus += 1
        case ("=", _), ("+", _): tab.zoom(1)
        case ("-", false): tab.zoom(-1)
        case ("0", false): tab.zoom(0)
        default: return false
        }
        return true
    }
}
