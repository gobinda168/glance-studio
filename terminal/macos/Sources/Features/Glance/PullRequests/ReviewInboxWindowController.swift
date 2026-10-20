import AppKit
import Combine
import GlanceCore
import SwiftUI

/// The Review comments tab (spec 2026-10-07-pr-manager-design.md, "Navigation"; the canvas's board 4): the review
/// threads of a repository's open pull requests, by pull request, with the filters in the side bar. One per repository
/// per window.
@MainActor
final class ReviewInboxWindowController: NSWindowController, NSWindowDelegate, GlanceTabController, GlancePaneOwner,
    ObservableObject {
    static let kind = "reviewInbox"

    /// "owner/name".
    let repository: String
    /// The project folder on this Mac, where pull requests are checked out and fixed: the folder it was opened from,
    /// else the repository's folder, which a clone or link fills while the tab is open; nil while it isn't on this Mac.
    @Published private(set) var root: String?
    private var folderWatch: AnyCancellable?
    var tabKind: String { Self.kind }
    var tabKey: String { repository }
    @Published var glancePaneOpen: Bool = GlanceTerminalHost.paneOpenDefault
    @Published var glancePlacement: PaneLayout.Placement?
    /// The page's filter, chosen in the side bar.
    @Published var filter: ReviewInbox.Filter = .unresolved
    /// The side bar shows the pull requests list instead of the filters (its back row); opening the inbox again, or
    /// any other tab, puts the filters back.
    @Published var sidebarShowsList = false
    /// Pull requests showing every thread, not only their first three.
    @Published var expanded: Set<Int> = []
    /// The thread whose reply field is open, and what's typed in it.
    @Published var replying: String?
    @Published var reply = ""
    var glanceDirectory: String? { root }

    init(repository: String, root: String?) {
        self.repository = repository
        self.root = root ?? RepositoryFoldersModel.shared.folder(for: repository)
        let window = GlanceTabWindow()
        super.init(window: window)
        window.delegate = self
        window.title = "Review comments"
        window.contentView = PullRequestHostingView(rootView: ReviewInboxTabView(controller: self))
        if root == nil {
            // Opened without a folder: a clone or link of the repository gives it one.
            folderWatch = RepositoryFoldersModel.shared.$map.sink { [weak self] map in
                let folder = map.folder(for: repository)
                if self?.root != folder { self?.root = folder }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Opens `repository`'s inbox in `parent`'s tab group, or brings it forward; on `filter` when given. The side bar
    /// shows its filters.
    @discardableResult
    static func open(repository: String, root: String?, filter: ReviewInbox.Filter? = nil,
                     from parent: NSWindow?) -> ReviewInboxWindowController? {
        let controller = GlanceTabHost.open(kind: kind, key: repository, from: parent) {
            ReviewInboxWindowController(repository: repository, root: root)
        }
        if let filter { controller?.filter = filter }
        controller?.sidebarShowsList = false
        SidebarModeModel.shared.show(.pullRequests)
        return controller
    }

    /// View › Review Comments: the inbox of the key window's project. Its repository comes from the side bar when it has
    /// read it, else from git's remotes.
    static func openForKeyWindow() {
        let parent = NSApp.keyWindow
        guard let folder = (parent?.windowController as? GlancePaneOwner)?.glanceDirectory, !folder.isEmpty else {
            NSSound.beep()
            return
        }
        let root = ProjectRoot.find(from: folder)
        if let repository = RepositoryFoldersModel.shared.repository(ofFolder: root) {
            open(repository: repository, root: root, from: parent)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let remotes = GitHubCLI.execute("/usr/bin/git", ["-C", root, "remote", "-v"])
            let repository = remotes.flatMap { result in
                result.status == 0 ? PullRequests.repository(remotes: String(decoding: result.output, as: UTF8.self)) : nil
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let repository {
                        ReviewInboxWindowController.open(repository: repository, root: root, from: parent)
                    } else {
                        NSSound.beep()
                    }
                }
            }
        }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        GlanceTerminalHost.shared.focusChanged(self)
    }

    func windowWillClose(_ notification: Notification) {
        folderWatch = nil
        GlanceTabHost.closed(self)
        // The view holds this controller, which holds the window: once it has closed, let go of the view.
        DispatchQueue.main.async { [weak window] in MainActor.assumeIsolated { window?.contentView = nil } }
    }
}
