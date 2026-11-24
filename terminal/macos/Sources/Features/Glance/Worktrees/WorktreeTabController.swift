import AppKit
import GlanceCore
import SwiftUI

/// A worktree's page as a tab (spec §3, "Worktree page"): one per worktree per window.
@MainActor
final class WorktreeTabController: NSWindowController, NSWindowDelegate, GlanceTabController {
    static let kind = "worktree"

    let path: String
    var tabKind: String { Self.kind }
    var tabKey: String { path }

    init(path: String) {
        self.path = path
        let window = GlanceTabWindow()
        super.init(window: window)
        window.delegate = self
        window.title = URL(fileURLWithPath: path).lastPathComponent
        window.contentView = PullRequestHostingView(rootView: WorktreePage(path: path))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @discardableResult
    static func open(path: String, from parent: NSWindow?) -> WorktreeTabController? {
        // The worktree page stays reachable from Command, which takes over the Worktrees strip item.
        let features = StudioFeatures.shared
        guard features.isOn(.worktrees) || features.isOn(.commandCenter) else { return nil }
        SidebarModeModel.shared.show(features.isOn(.commandCenter) ? .command : .worktrees)
        return GlanceTabHost.open(kind: kind, key: path, from: parent) { WorktreeTabController(path: path) }
    }

    func windowWillClose(_ notification: Notification) {
        GlanceTabHost.closed(self)
        DispatchQueue.main.async { [weak window] in MainActor.assumeIsolated { window?.contentView = nil } }
    }
}

/// Opens a terminal tab in a folder, optionally running Claude (or resuming a session) in it.
@MainActor
enum WorktreeTerminal {
    static func open(in path: String, claude: Bool, resume: String? = nil, near window: NSWindow?) {
        guard let app = NSApp.delegate as? AppDelegate else { return }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = path
        // Only a real session id is typed into the shell (the ids come from files hooks wrote).
        if let resume, UUID(uuidString: resume) != nil {
            config.initialInput = "claude --resume \(resume)\n"
        } else if claude {
            config.initialInput = "claude\n"
        }
        TabSidebarModel.newTerminalTab(app.ghostty, joining: window, withBaseConfig: config)
    }
}
