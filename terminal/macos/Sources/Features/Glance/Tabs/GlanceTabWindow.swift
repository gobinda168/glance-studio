import AppKit

/// The window of a non-terminal tab (the editor, later an automation agent). It subclasses `TerminalWindow` because
/// Ghostty's `relabelTabs()` casts a tab group's windows to `[TerminalWindow]` as a whole: one plain NSWindow in the
/// group would make that cast fail for every tab, and the ⌘1–⌘9 tab shortcuts would stop working.
final class GlanceTabWindow: TerminalWindow {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        isRestorable = false // such a tab is not restored as a terminal on relaunch
        awakeFromNib() // the setup a terminal window gets from its nib: tabbing mode, config-derived style
    }
}
