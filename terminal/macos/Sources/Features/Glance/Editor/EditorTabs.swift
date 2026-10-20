import AppKit
import GlanceCore
import GlanceKit

/// An editor tab of either kind (Razor Code or GS Code), as links, Claude's marks and the swap see it.
@MainActor
protocol EditorTab: GlanceTabController, Sendable {
    var root: String { get }
    var editorKind: EditorKind { get }
    /// The open file, relative to the root, when the tab knows it.
    var currentFile: String? { get }
    func openFile(_ relative: String, line: Int?, column: Int?)
    func showClaudeChanges(_ marks: [String: [LineMark]])
    /// The files Claude edited in the latest session, relative to the root (the Changes views mark them).
    func showClaudeFiles(_ paths: [String])
}

/// Opening, finding and swapping editor tabs (spec 2026-10-06-vscode-editor-tab-design.md, "Two editors").
@MainActor
enum EditorTabs {
    /// GS Code is offered: its feature is on. Off, every editor tab is Razor Code.
    static var offersGSCode: Bool { StudioFeatures.shared.isOn(.gsCode) }

    /// The kind Settings chose: Razor Code unless changed (always Razor Code while GS Code isn't offered).
    static var preferredKind: EditorKind { offersGSCode ? Prefs.editorKind : .razor }

    static func all() -> [any EditorTab] {
        EditorKind.allCases.flatMap { GlanceTabHost.controllers(kind: $0.rawValue) }.compactMap { $0 as? any EditorTab }
    }

    /// The project's tab of that kind in `parent`'s window, made if needed (always made when `reuse` is off, as File ›
    /// New Editor Tab does). GS Code's first tab asks before its download; declining opens Razor Code instead.
    @discardableResult
    static func open(_ kind: EditorKind, root: String, from parent: NSWindow?, reuse: Bool = true) -> (any EditorTab)? {
        switch kind {
        case .razor:
            return GlanceTabHost.open(kind: kind.rawValue, key: root, from: parent, reuse: reuse) {
                RazorWindowController(root: root)
            }
        case .studio:
            guard offersGSCode, confirmStudioDownload() else { return open(.razor, root: root, from: parent, reuse: reuse) }
            return GlanceTabHost.open(kind: kind.rawValue, key: root, from: parent, reuse: reuse) {
                StudioWindowController(root: root)
            }
        }
    }

    /// Before GS Code's first download: what it costs, and the choice to stay with Razor Code.
    private static func confirmStudioDownload() -> Bool {
        let server = EditorServerManager.shared
        guard server.needsDownloadConsent else { return true }
        let megabytes = server.downloadSize / 1_000_000
        let alert = NSAlert()
        alert.messageText = "Download GS Code?"
        alert.informativeText = """
            GS Code is a full VS Code workbench (extensions, IntelliSense, debugging). The first time, it \
            downloads about \(megabytes) MB (the open-source VSCodium server, from GitHub) and keeps it for next time. \
            Each GS Code tab uses about 1 GB of memory.

            Razor Code needs no download.
            """
        alert.addButton(withTitle: "Download \(megabytes) MB")
        alert.addButton(withTitle: "Use Razor Code")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        server.agreeToDownload()
        return true
    }

    /// Where a link to one of the project's files goes: its open editor tab in this window, else a new one of the
    /// chosen kind.
    static func forLink(root: String, from window: NSWindow) -> (any EditorTab)? {
        let openKinds = all().filter { $0.root == root && $0.window?.tabGroup === window.tabGroup }.map(\.editorKind)
        return open(EditorKind.target(open: openKinds, preferred: preferredKind), root: root, from: window)
    }

    /// Opens the project in the other editor (with the same file, when known) and closes this tab. Razor Code asks
    /// about unsaved changes first; Cancel leaves both tabs open. Declining GS Code's download leaves this tab.
    static func swap(_ tab: any EditorTab) {
        guard let window = tab.window,
              let other = open(tab.editorKind.other, root: tab.root, from: window),
              other.editorKind != tab.editorKind else { return }
        if let file = tab.currentFile { other.openFile(file, line: nil, column: nil) }
        window.performClose(nil)
    }
}
