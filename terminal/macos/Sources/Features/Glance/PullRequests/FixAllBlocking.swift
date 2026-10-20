import GlanceCore
import SwiftUI

/// Fix all blocking with Claude (⇧⌘I, the inbox's glow ring; spec "Pages → Review comments"). The blocking threads of
/// the pull request checked out in the project go to Claude in one go. When none of the pull requests with blocking
/// threads is checked out, it offers to check out the one with the most, then fixes those.
struct FixAllBlockingButton: View {
    @ObservedObject var controller: ReviewInboxWindowController
    let board: PullRequests.Board
    let reviews: ReviewThreads.BoardThreads
    @ObservedObject private var fixes = FixJobs.shared
    @ObservedObject private var inbox = ReviewInboxStore.shared
    @ObservedObject private var store = PullRequestStore.shared
    /// The pull request offered for checking out, and its blocking threads.
    @State private var offer: PullRequests.PullRequest?
    @State private var offered: [ReviewThreads.Thread] = []
    @State private var offering = false

    var body: some View {
        let root = controller.root
        let plan = ReviewInbox.fixAll(board.waitingOnYou + board.yours, threads: reviews.threads,
                                      branch: root.flatMap { GitHead.branch(inFolder: $0) })
        let claude = inbox.claudeInstalled != false
        let busy = root.map { fixes.isBusy(root: $0) } ?? false
        VStack(alignment: .trailing, spacing: 6) {
            GlowPill(title: "Fix all blocking with Claude", hint: "⇧⌘I", busy: checkingOut,
                     enabled: root != nil && plan != .nothing && claude && !busy, height: 32) {
                start(plan)
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .help(root == nil ? LocalFolderNotice.needs(board.repository) : tooltip(plan, claude: claude, busy: busy))
            if let offer, let error = store.entry(key(offer)).errors["checkout"] {
                InlineError(message: error)
            }
        }
        .confirmationDialog(offer.map { "Check out #\($0.number)?" } ?? "", isPresented: $offering,
                            titleVisibility: .visible) {
            if let offer {
                Button("Check Out and Fix") { checkOutAndFix(offer, offered) }
            }
        } message: {
            if let offer {
                Text("None of the pull requests with blocking threads is checked out here. #\(offer.number) has the "
                     + "most (\(offered.count)): Glance checks it out, then Claude fixes them.")
            }
        }
    }

    /// The offered pull request is being checked out.
    private var checkingOut: Bool {
        offer.map { store.entry(key($0)).busy.contains("checkout") } ?? false
    }

    private func start(_ plan: ReviewInbox.FixAll) {
        switch plan {
        case .fix(let pullRequest, let threads):
            fix(pullRequest, threads)
        case .checkOut(let pullRequest, let threads):
            offer = pullRequest
            offered = threads
            offering = true
        case .nothing:
            break
        }
    }

    /// gh checks the pull request out in the project (it refuses over uncommitted changes, and nothing is touched);
    /// the fix starts only once that worked.
    private func checkOutAndFix(_ pullRequest: PullRequests.PullRequest, _ threads: [ReviewThreads.Thread]) {
        guard let root = controller.root else { return }
        PullRequestStore.shared.perform(.checkout, key: key(pullRequest), root: root) {
            fix(pullRequest, threads)
        }
    }

    private func fix(_ pullRequest: PullRequests.PullRequest, _ threads: [ReviewThreads.Thread]) {
        guard let root = controller.root else { return }
        FixJobs.shared.dismiss(root: root)
        FixJobs.shared.fix(threads, number: pullRequest.number, title: pullRequest.title, key: key(pullRequest),
                           root: root, window: controller.window)
    }

    private func key(_ pullRequest: PullRequests.PullRequest) -> PullRequestStore.Key {
        PullRequestStore.Key(repository: board.repository, number: pullRequest.number)
    }

    private func tooltip(_ plan: ReviewInbox.FixAll, claude: Bool, busy: Bool) -> String {
        if !claude { return "Install Claude Code to fix with Claude" }
        if busy { return "A fix is under way in this project" }
        switch plan {
        case .fix(let pullRequest, let threads):
            let what = threads.count == 1 ? "blocking thread" : "\(threads.count) blocking threads"
            return "Claude fixes #\(pullRequest.number)'s \(what) in your working tree; you accept or reject (⇧⌘I)"
        case .checkOut(let pullRequest, _):
            return "Checks out #\(pullRequest.number) first (⇧⌘I)"
        case .nothing:
            return "Nothing blocks merging"
        }
    }
}
