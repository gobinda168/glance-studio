import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The window controller of a Razor Code tab (the built-in Monaco editor): one project root, Monaco on the left, the
/// Glance pane on the right.
@MainActor
final class RazorWindowController: NSWindowController, NSWindowDelegate, EditorTab, GlancePaneOwner, ObservableObject {
    let root: String
    let web: EditorWeb
    var tabKind: String { EditorKind.razor.rawValue }
    var editorKind: EditorKind { .razor }
    var currentFile: String? { web.openPath }
    var tabKey: String { root }
    @Published var glancePaneOpen: Bool = GlanceTerminalHost.paneOpenDefault
    @Published var glancePlacement: PaneLayout.Placement?
    var glanceDirectory: String? { root }

    init(root: String) {
        self.root = root
        web = EditorWeb(root: root, webDirectory: Resources.web)
        let window = GlanceTabWindow()
        super.init(window: window)
        window.delegate = self
        web.onChange = { [weak self] in
            guard let self else { return }
            self.updateTitle()
            GlanceTerminalHost.shared.chatContextChanged(self)
        }
        window.contentView = NSHostingView(rootView: RazorTabView(controller: self))
        updateTitle()
        GlanceTerminalHost.shared.deliverClaudeChanges(to: self) // a new editor tab starts with the latest marks
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func updateTitle() {
        let folder = URL(fileURLWithPath: root).lastPathComponent
        var title = "⚡ " + folder
        if let path = web.openPath { title += " — " + (path as NSString).lastPathComponent }
        if web.isDirty { title += " •" }
        window?.title = title
    }

    /// Opens a file of this project (a path relative to the root) in a tab, at a line.
    func openFile(_ relative: String, line: Int?, column: Int?) {
        web.open(path: relative, line: line, column: column)
    }

    func showClaudeChanges(_ marks: [String: [LineMark]]) { web.showClaudeChanges(marks) }
    func showClaudeFiles(_ paths: [String]) { web.showClaudeFiles(paths) }

    // MARK: Menu actions (the responder chain finds them while this tab is key)

    @objc func glanceEditorSave(_ sender: Any?) { web.save() }
    @objc func glanceEditorQuickOpen(_ sender: Any?) { web.quickOpen() }
    @objc func glanceEditorFindInProject(_ sender: Any?) { web.findInProject() }
    @objc func glanceEditorNextChange(_ sender: Any?) { web.nextClaudeChange() }
    @objc func glanceEditorPreviousChange(_ sender: Any?) { web.previousClaudeChange() }
    @objc func glanceEditorClearChanges(_ sender: Any?) { web.clearClaudeChanges() }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        GlanceTerminalHost.shared.focusChanged(self)
        web.checkExternalChange()
    }

    /// Unsaved edits are never dropped silently.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard web.isDirty else { return true }
        let alert = NSAlert()
        let names = web.dirtyPaths.map { ($0 as NSString).lastPathComponent }
        alert.messageText = names.count == 1 ? "Save changes to \(names[0])?" : "Save changes to \(names.count) files?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                self?.web.save(all: true) { saved in if saved { self?.closeWithoutAsking() } }
            case .alertSecondButtonReturn:
                self?.closeWithoutAsking()
            default:
                break
            }
        }
        return false
    }

    private func closeWithoutAsking() {
        window?.delegate = nil
        window?.close()
        windowWillCloseCleanup()
    }

    func windowWillClose(_ notification: Notification) { windowWillCloseCleanup() }

    private func windowWillCloseCleanup() {
        web.close()
        GlanceTabHost.closed(self)
    }
}
