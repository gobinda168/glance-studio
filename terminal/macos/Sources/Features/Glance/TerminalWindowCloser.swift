import AppKit

/// Closes every terminal, editor and Home window one at a time through the normal close path, so an unsaved editor
/// tab asks first. Reports false if the user cancelled a prompt (a window stayed open).
@MainActor
enum TerminalWindowCloser {
    static var hasOpenWindows: Bool {
        NSApp.windows.contains { isGlanceWindow($0) && $0.isVisible }
    }

    static func closeAll(_ done: @escaping (Bool) -> Void) {
        guard let window = NSApp.windows.first(where: { isGlanceWindow($0) && $0.isVisible }) else { return done(true) }
        let center = NotificationCenter.default
        var tokens: [NSObjectProtocol] = []
        var handled = false
        func finish(_ next: @escaping () -> Void) {
            guard !handled else { return }
            handled = true
            tokens.forEach(center.removeObserver)
            DispatchQueue.main.async(execute: next)
        }
        tokens.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            finish { closeAll(done) }
        })
        tokens.append(center.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) { _ in
            // The prompt ended: if the window is still there afterwards, the user said Cancel.
            DispatchQueue.main.async { if window.isVisible { finish { done(false) } } }
        })
        window.performClose(nil)
        // A window that never reports (a modal alert nobody answers) doesn't hold the switch forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { if window.isVisible { finish { done(false) } } }
    }

    private static func isGlanceWindow(_ window: NSWindow) -> Bool {
        window.windowController is GlancePaneOwner || window.windowController is HomeWindowController
    }
}
