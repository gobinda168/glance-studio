import AppKit
import Combine
import GlanceCore
import GlanceKit
import SwiftUI

/// A PR tab (spec 2026-10-07-pr-manager-design.md, "Navigation"): one pull request of one repository, opened from the
/// Pull requests side bar or a link, with Overview, Files, Commits and Checks. One per pull request per window.
@MainActor
final class PullRequestWindowController: NSWindowController, NSWindowDelegate, GlanceTabController, GlancePaneOwner,
    ObservableObject {
    static let kind = "pullRequest"

    enum Section: Hashable { case overview, files, commits, checks }

    let key: PullRequestStore.Key
    /// The project folder on this Mac, where Check out, fixes and Ask Claude run: the folder it was opened from, else
    /// the repository's folder (`RepositoryFoldersModel`), which a clone or link fills while the tab is open. Nil while
    /// the repository isn't on this Mac (spec 2026-10-08-pr-repositories-design.md, "Folders on this Mac").
    @Published private(set) var root: String?
    var tabKind: String { Self.kind }
    var tabKey: String { "\(key.repository)#\(key.number)" }
    @Published var glancePaneOpen: Bool = GlanceTerminalHost.paneOpenDefault
    @Published var glancePlacement: PaneLayout.Placement?
    @Published var section: Section = .overview
    /// The Files page's file, by path; nil shows the first.
    @Published var file: String?
    /// The commit whose changes the Files page shows, read-only; nil for the pull request's.
    @Published var commit: String?
    /// A line the Files page scrolls to once (a thread opened from the Overview).
    @Published var focus: ReviewThreads.Anchor?
    var glanceDirectory: String? { root }

    private var titleWatch: AnyCancellable?
    private var folderWatch: AnyCancellable?

    init(repository: String, number: Int, root: String?) {
        key = PullRequestStore.Key(repository: repository, number: number)
        self.root = root ?? RepositoryFoldersModel.shared.folder(for: repository)
        let window = GlanceTabWindow()
        super.init(window: window)
        window.delegate = self
        window.title = "PR #\(number)"
        window.contentView = PullRequestHostingView(rootView: PullRequestTabView(controller: self))
        // The tab's title follows the pull request's (or the issue's).
        let key = self.key
        titleWatch = PullRequestStore.shared.$entries.sink { [weak self] entries in self?.updateTitle(entries[key]) }
        if root == nil {
            // Opened without a folder: a clone or link of the repository gives it one.
            folderWatch = RepositoryFoldersModel.shared.$map.sink { [weak self] map in
                let folder = map.folder(for: repository)
                if self?.root != folder { self?.root = folder }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Opens `number`'s tab in `parent`'s tab group, or brings it forward when it's open there.
    @discardableResult
    static func open(repository: String, number: Int, root: String?, from parent: NSWindow?) -> PullRequestWindowController? {
        GlanceTabHost.open(kind: kind, key: "\(repository)#\(number)", from: parent) {
            PullRequestWindowController(repository: repository, number: number, root: root)
        }
    }

    /// Review changes (⇧⌘R): the Files page, on `path` and `focus` when given, with the changed files in the side bar.
    func reviewChanges(path: String? = nil, focus: ReviewThreads.Anchor? = nil) {
        commit = nil
        if let path { file = path }
        self.focus = focus
        section = .files
        SidebarModeModel.shared.show(.pullRequests)
    }

    /// One commit's changes on the Files page, read-only.
    func showCommit(_ sha: String) {
        commit = sha
        file = nil
        focus = nil
        section = .files
        SidebarModeModel.shared.show(.pullRequests)
    }

    private func updateTitle(_ entry: PullRequestStore.Entry?) {
        let title: String
        if let page = entry?.page {
            title = "PR #\(page.number) — \(page.title)"
        } else if let issue = entry?.issue {
            title = "Issue #\(issue.number) — \(issue.title)"
        } else {
            title = "PR #\(key.number)"
        }
        if window?.title != title { window?.title = title }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        GlanceTerminalHost.shared.focusChanged(self)
    }

    func windowWillClose(_ notification: Notification) {
        DiffAsks.shared.closeAll(DiffAsks.key(key))
        titleWatch = nil
        folderWatch = nil
        GlanceTabHost.closed(self)
        // The view holds this controller, which holds the window: once it has closed, let go of the view.
        DispatchQueue.main.async { [weak window] in MainActor.assumeIsolated { window?.contentView = nil } }
    }
}

/// A PR tab's content takes a click while its window is in back (the Review comments tab's too).
final class PullRequestHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Where a link on a PR page goes (spec, "In the app only"): this repository's pull requests and issues open as tabs in
/// this window; anything else opens in the browser.
@MainActor
enum PullRequestLinkRouter {
    static func open(_ url: URL, from controller: PullRequestWindowController) {
        open(url, repository: controller.key.repository, root: controller.root, from: controller.window)
    }

    /// A link on a page of `repository`, opened from `window` (the inbox has no pull request of its own).
    static func open(_ url: URL, repository: String, root: String?, from window: NSWindow?) {
        switch PullRequestLinks.target(url, repository: repository) {
        case .number(let number):
            PullRequestWindowController.open(repository: repository, number: number, root: root, from: window)
        case .external(let url):
            NSWorkspace.shared.open(url)
        }
    }
}
