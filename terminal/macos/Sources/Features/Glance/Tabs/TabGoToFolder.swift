import AppKit
import GlanceCore

/// A terminal tab's Go to Folder… (its row's 📁 on hover, and its right-click menu): brings the tab to the front, asks
/// for a folder starting at the tab's own, and types `cd` into its shell.
@MainActor
enum TabGoToFolder {
    static func pick(for window: NSWindow) {
        guard let controller = window.windowController as? TerminalController else { return }
        window.tabGroup?.selectedWindow = window
        window.makeKey()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Go"
        panel.message = "Choose a folder for this terminal"
        if let folder = controller.glanceDirectory, !folder.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: folder, isDirectory: true)
        }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url, let surface = controller.focusedSurface,
                  let model = surface.surfaceModel else { return }
            window.makeFirstResponder(surface)
            // A paste, then Return a moment later so the shell sees a keypress, not more pasted text.
            model.sendText(GoToFolder.command(path: url.path))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                model.sendKeyEvent(Ghostty.Input.KeyEvent(key: .enter, action: .press))
            }
        }
    }
}
