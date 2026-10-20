import AppKit
import GlanceCore

/// ⌘V pastes an image into Claude Code: Claude reads a pasted image only on ⌃V, and a terminal's ⌘V pastes text, so
/// with an image (and no text) on the clipboard and Claude in front, ⌘V reaches the terminal as ⌃V.
@MainActor
enum ClaudeImagePaste {
    /// True when `event` was ⌘V and went to `view` as ⌃V.
    static func performKeyEquivalent(_ event: NSEvent, in view: Ghostty.SurfaceView) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard flags == .command, event.charactersIgnoringModifiers?.lowercased() == "v",
              clipboardHoldsImageOnly(), claudeInFront(of: view) else { return false }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let key = NSEvent.keyEvent(
                with: type, location: event.locationInWindow, modifierFlags: .control, timestamp: event.timestamp,
                windowNumber: event.windowNumber, context: nil, characters: "\u{16}", charactersIgnoringModifiers: "v",
                isARepeat: false, keyCode: event.keyCode) else { return false }
            if type == .keyDown { view.keyDown(with: key) } else { view.keyUp(with: key) }
        }
        return true
    }

    /// An image (a screenshot, a copied picture) and no text: with text, ⌘V pastes the text as always.
    private static func clipboardHoldsImageOnly() -> Bool {
        let board = NSPasteboard.general
        return board.string(forType: .string) == nil && board.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    /// The terminal's foreground program is Claude (the side bar's command chip says "claude").
    private static func claudeInFront(of view: Ghostty.SurfaceView) -> Bool {
        guard let pid = view.surfaceModel?.foregroundPID, let process = ProcessArguments.read(pid: pid),
              let command = CommandName.chip(executable: process.executable, arguments: process.arguments)
        else { return false }
        return command == "claude" || command.hasPrefix("claude ")
    }
}
