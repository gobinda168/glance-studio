import AppKit
import GlanceCore
import GlanceKit

/// Where a notice's Open goes (spec 2026-10-09-notifications-design.md): a pull request or issue in the PR manager
/// (never github.com), a Slack workspace's tab, the terminal it came from, or the meeting's link.
@MainActor
enum NoticeRouter {
    static func open(_ notice: Notice) {
        // The Develop menu's test notice goes nowhere.
        guard notice.meta["test"] == nil else { return }
        let window = SettingsTabController.frontWindow
        NSApp.activate(ignoringOtherApps: true)
        switch notice.target {
        case .pullRequest(let repository, let number, let path, let line):
            guard let controller = PullRequestWindowController.open(repository: repository, number: number,
                                                                    root: nil, from: window) else { return }
            if let path {
                controller.reviewChanges(path: path, focus: line.map { ReviewThreads.Anchor(side: .right, line: $0) })
            }
        case .issue(let repository, let number):
            _ = PullRequestWindowController.open(repository: repository, number: number, root: nil, from: window)
        case .slack(let team, let notificationID, _):
            BrowserTabController.openSlack(teamID: team, from: window)
            if let notificationID {
                NotificationCenter.default.post(name: .init("dev.glance.slackNoticeClick"), object: nil,
                                                userInfo: ["team": team, "id": notificationID])
            }
        case .terminal(let surface, let cwd):
            focusTerminal(surface: surface, cwd: cwd)
            // A `tell` made while Studio was behind: its card shows.
            if notice.meta[GlanceTerminalHost.openCardMeta] != nil { GlanceTerminalHost.shared.showCard() }
        case .meeting(_, let joinURL):
            if let joinURL { NSWorkspace.shared.open(joinURL) }
        case .link(let url):
            NSWorkspace.shared.open(url)
        case .none:
            break
        }
    }

    /// The split the notice came from (by its id), else the first split in `cwd` (or a folder inside it), focused
    /// in its window and tab. Nothing when it's gone.
    private static func focusTerminal(surface: String?, cwd: String?) {
        if let surface, let uuid = UUID(uuidString: surface),
           let view = (NSApp.delegate as? AppDelegate)?.findSurface(forUUID: uuid) {
            return focus(view)
        }
        guard let cwd else { return }
        let controllers = TerminalController.all
        // The split in front of each window first, then the rest; the folder itself before one inside it.
        let views = controllers.compactMap(\.focusedSurface)
            + controllers.flatMap { controller in controller.surfaceTree.filter { $0 !== controller.focusedSurface } }
        let inside = cwd.hasSuffix("/") ? cwd : cwd + "/"
        if let view = views.first(where: { $0.pwd == cwd }) ?? views.first(where: { $0.pwd?.hasPrefix(inside) == true }) {
            focus(view)
        }
    }

    private static func focus(_ view: Ghostty.SurfaceView) {
        guard let window = view.window else { return }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
        Ghostty.moveFocus(to: view)
    }
}
