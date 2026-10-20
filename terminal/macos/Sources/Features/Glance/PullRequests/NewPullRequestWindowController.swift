import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The New pull request tab (spec 2026-10-07-pr-manager-design.md, "Navigation"; the canvas's board 3). It shows the
/// project's branch against its base and the form, and Create turns it into the new pull request's tab. One per
/// project per window, titled "New pull request", with "•" once edited.
@MainActor
final class NewPullRequestWindowController: NSWindowController, NSWindowDelegate, GlanceTabController, GlancePaneOwner,
    ObservableObject {
    static let kind = "newPullRequest"

    /// The project folder: its branch, git, tests and Claude.
    let root: String
    var tabKind: String { Self.kind }
    var tabKey: String { root }
    @Published var glancePaneOpen: Bool = GlanceTerminalHost.paneOpenDefault
    @Published var glancePlacement: PaneLayout.Placement?
    /// The branches the menus chose; nil for the default branch and the project's own.
    @Published var base: String?
    @Published var branch: String?
    @Published var title = "" { didSet { touched(title: true) } }
    @Published var body = "" { didSet { touched(title: false) } }
    @Published var reviewers: [String] = [] { didSet { changed() } }
    @Published var labels: [String] = [] { didSet { changed() } }
    @Published var issue: PullRequestActions.Issue? { didSet { changed() } }
    @Published var draft = false
    /// The side bar shows the pull requests list instead of this branch (its back row); opening the tab again puts the
    /// branch back.
    @Published var sidebarShowsList = false
    @Published var autoMerge = false
    /// Open diff: the branch's changes instead of the form.
    @Published var showingDiff = false
    /// Something was typed or chosen: the title says so, and Cancel asks first.
    @Published private(set) var edited = false
    private var quiet = false
    /// The user typed in the title or the description (not a prefill, and not Claude's draft).
    private var titleTouched = false
    private var bodyTouched = false
    /// Claude's draft (spec: "the PR draft"):
    /// - whether it's under way, and why it failed;
    /// - whether the fields hold it (the note says so), and from how many commits;
    /// - a redraft waiting for Replace, because the user typed in the fields.
    @Published private(set) var drafting = false
    @Published private(set) var draftError: String?
    @Published private(set) var drafted = false
    @Published private(set) var draftCommits = 0
    @Published var waitingDraft: PRDraft?
    private var draftedOnce = false
    private var draftRun: ClaudeOneShot.Run?
    var glanceDirectory: String? { root }

    /// Claude's title and description, and how many commits it read.
    struct PRDraft: Equatable {
        let title: String
        let body: String
        let commits: Int
    }

    init(root: String) {
        self.root = root
        let window = GlanceTabWindow()
        super.init(window: window)
        window.delegate = self
        window.title = "New pull request"
        window.contentView = PullRequestHostingView(rootView: NewPullRequestTabView(controller: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Opens `root`'s New pull request tab in `parent`'s tab group, or brings it forward; the side bar shows its branch.
    @discardableResult
    static func open(root: String, from parent: NSWindow?) -> NewPullRequestWindowController? {
        let controller = GlanceTabHost.open(kind: kind, key: root, from: parent) {
            NewPullRequestWindowController(root: root)
        }
        controller?.sidebarShowsList = false
        SidebarModeModel.shared.show(.pullRequests)
        return controller
    }

    /// ⌥⌘P: the key window's project's New pull request tab.
    static func openForKeyWindow() {
        let parent = NSApp.keyWindow
        guard let folder = (parent?.windowController as? GlancePaneOwner)?.glanceDirectory, !folder.isEmpty else {
            NSSound.beep()
            return
        }
        open(root: ProjectRoot.find(from: folder), from: parent)
    }

    /// A title from the branch (its one commit, or Claude's draft), without counting as an edit.
    func prefill(title: String) {
        guard self.title.isEmpty, !edited, !title.isEmpty else { return }
        quiet = true
        self.title = title
        quiet = false
    }

    private func touched(title isTitle: Bool) {
        if !quiet {
            if isTitle { titleTouched = true } else { bodyTouched = true }
        }
        changed()
    }

    private func changed() {
        guard !quiet, !edited else { return }
        edited = true
        window?.title = "New pull request •"
    }

    /// Claude drafts the title and description from the branch's commits, its diff and the repository's template
    /// (read-only `claude -p` in the project). The first draft runs once the tab has read its branch and fills what the
    /// user hasn't typed. Redraft (⌘I) replaces both, asking first when the user typed in them.
    func draft(_ compare: NewPullRequestStore.Compare, redraft: Bool) {
        guard !drafting, !compare.commits.isEmpty, redraft || !draftedOnce else { return }
        draftedOnce = true
        drafting = true
        draftError = nil
        let root = self.root
        let template = PullRequestClaude.template { name in
            try? String(contentsOfFile: (root as NSString).appendingPathComponent(name), encoding: .utf8)
        }
        let prompt = PullRequestClaude.prDraftPrompt(
            branch: compare.branch, base: compare.base, repository: compare.repository,
            commits: compare.commits.map { "\($0.hash) \($0.subject)" }, diff: compare.diffText, template: template)
        let commits = compare.commits.count
        draftRun = ClaudeOneShot.run(arguments: PullRequestClaude.prDraftArguments(), prompt: prompt,
                                     folder: root) { [weak self] result in
            self?.drafted(result, commits: commits, redraft: redraft)
        }
    }

    private func drafted(_ result: Result<String, PullRequestClaude.Failure>, commits: Int, redraft: Bool) {
        drafting = false
        draftRun = nil
        switch result {
        case .failure(let failure) where failure.kind == .notInstalled:
            break // the status bar says so; the fields stay as they are
        case .failure(let failure):
            draftError = failure.message
        case .success(let answer):
            let parsed = PullRequestClaude.prDraft(answer)
            let draft = PRDraft(title: parsed.title, body: parsed.body, commits: commits)
            let typed = (titleTouched && !title.isEmpty) || (bodyTouched && !body.isEmpty)
            if redraft && typed { waitingDraft = draft } else { apply(draft, replacing: redraft) }
        }
    }

    /// Puts Claude's draft in: over both fields after Redraft or Replace, else into what the user hasn't typed.
    func apply(_ draft: PRDraft, replacing: Bool) {
        quiet = true
        if replacing || !titleTouched, !draft.title.isEmpty { title = draft.title }
        if replacing || !bodyTouched, !draft.body.isEmpty { body = draft.body }
        quiet = false
        if replacing {
            titleTouched = false
            bodyTouched = false
        }
        drafted = true
        draftCommits = draft.commits
        waitingDraft = nil
    }

    /// Create worked: the new pull request's tab takes this one's place.
    func created(_ number: Int, repository: String) {
        PullRequestWindowController.open(repository: repository, number: number, root: root, from: window)
        PullRequestsModel.shared.load(repository, force: true)
        window?.close()
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        GlanceTerminalHost.shared.focusChanged(self)
    }

    func windowWillClose(_ notification: Notification) {
        DiffAsks.shared.closeAll(DiffAsks.key(newPullRequest: root))
        GlanceTabHost.closed(self)
        // The view holds this controller, which holds the window: once it has closed, let go of the view.
        DispatchQueue.main.async { [weak window] in MainActor.assumeIsolated { window?.contentView = nil } }
    }
}
