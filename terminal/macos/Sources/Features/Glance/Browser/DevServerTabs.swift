import AppKit
import GlanceCore

/// Dev servers in the Browser (DevServerLinks): a dev server's page that a terminal opens, a ⌘-clicked link or a dev
/// server's `BROWSER` call, shows in a Browser tab. The tab already on that server comes forward; else a new tab opens
/// in the terminal's window.
@MainActor
enum DevServerTabs {
    static var isOn: Bool { BrowserData.opensDevServers && StudioFeatures.shared.isOn(.browser) }

    /// True when `text` is a dev server's page and a Browser tab shows it; false leaves it to the caller (the setting
    /// is off, or it isn't a page on this Mac).
    static func open(_ text: String, from window: NSWindow?) -> Bool {
        guard isOn, let url = DevServerLinks.devServerURL(text) else { return false }
        if let tab = BrowserTabController.all.first(where: { tab in
            tab.state.url.map { DevServerLinks.sameOrigin($0, url) } ?? false
        }) {
            if let current = tab.state.url, DevServerLinks.reloads(current, for: url) {
                tab.webView?.reload()
            } else {
                tab.go(url)
            }
            tab.bringForward()
            return true
        }
        return BrowserTabController.open(url: url, from: window ?? NSApp.keyWindow) != nil
    }

    /// `open` for a link clicked in a terminal. Ghostty calls open_url while it holds the surface's lock, and the new
    /// tab makes the terminal resign key, which takes that lock again (a hang), so the tab opens on the next turn.
    static func openFromClick(_ text: String, from window: NSWindow?) -> Bool {
        guard isOn, DevServerLinks.devServerURL(text) != nil else { return false }
        DispatchQueue.main.async { _ = open(text, from: window) }
        return true
    }

    /// The `BROWSER` helper handed Studio `text` from a terminal: a dev server's page in a Browser tab, any other web
    /// address in the default browser. False (the helper opens it itself) for anything else.
    static func openFromShell(_ text: String, from window: NSWindow?) -> Bool {
        if open(text, from: window) { return true }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return false }
        return NSWorkspace.shared.open(url)
    }
}
