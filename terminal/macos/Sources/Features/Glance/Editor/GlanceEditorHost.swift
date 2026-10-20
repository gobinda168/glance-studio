import AppKit
import GlanceCore

/// Opens files that terminal output or Glance's replies mention in the project's editor tab.
@MainActor
enum GlanceEditorHost {
    /// ⌘-click on `path`, `path:line` or `path:line:col` in a terminal. True when the link was a file Glance opened in
    /// an editor tab; false (so Ghostty does what it always did) when it isn't a regular file or there is no terminal
    /// window to resolve a relative path against.
    static func openFromTerminal(_ text: String) -> Bool {
        guard let window = NSApp.keyWindow,
              let terminal = window.windowController as? BaseTerminalController else { return false }
        return open(text, relativeTo: terminal.glanceDirectory, from: window)
    }

    /// A file named in a Glance reply was clicked. `directory` is the folder the pane follows.
    static func openFromPane(_ text: String, from window: NSWindow, directory: String?) -> Bool {
        open(text, relativeTo: directory, from: window)
    }

    private static func open(_ text: String, relativeTo directory: String?, from window: NSWindow) -> Bool {
        let link = PathLinks.parse(text)
        var bases: [String?] = [directory]
        if let directory { bases.append(ProjectRoot.find(from: directory)) }
        for base in bases {
            guard let absolute = PathLinks.resolve(link.path, relativeTo: base) else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: absolute, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            // A picture, PDF or document: Quick Look over the window, not the editor.
            if !FilePreview.opensInEditor(absolute) { return QuickLookPreview.shared.show(absolute) }
            let root = ProjectRoot.find(from: (absolute as NSString).deletingLastPathComponent)
            guard let relative = PathLinks.relative(absolute, inRoot: root) else { continue }
            let controller = EditorTabs.forLink(root: root, from: window)
            controller?.openFile(relative, line: link.line, column: link.column)
            return controller != nil
        }
        return false
    }
}
