import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// A PR tab (board 1): the side bar column; the pull request's page (header, tabs, the chosen page); the Glance pane;
/// and the status bar along the bottom. The page reads now and every minute while the tab is open.
struct PullRequestTabView: View {
    @ObservedObject var controller: PullRequestWindowController
    @ObservedObject private var store = PullRequestStore.shared
    @ObservedObject private var tabSidebar = TabSidebarModel.shared

    var body: some View {
        let entry = store.entry(controller.key)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if tabSidebar.isOpen {
                    SidebarColumn()
                }
                HSplitView {
                    content(entry)
                        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                        .background(StudioColors.background)
                        .overlay(alignment: .bottomTrailing) {
                            if controller.glancePaneOpen && controller.glancePlacement == .floating {
                                GlanceFloatView()
                            }
                        }
                    if controller.glancePaneOpen && controller.glancePlacement == .sidebar {
                        GlancePaneView()
                            .glanceSidebar()
                    }
                }
            }
            .glancePlacement($controller.glancePlacement)
            .activityStrip()
            PullRequestStatusBar(controller: controller, entry: entry)
        }
        .task(id: controller.key) {
            // While the tab is open: now, then every minute (the store skips a read that's still fresh), and not while Glance is behind another app.
            await ActivePolling.run(every: 60) { store.load(controller.key, root: controller.root) }
        }
    }

    @ViewBuilder private func content(_ entry: PullRequestStore.Entry) -> some View {
        if let page = entry.page, controller.section == .files {
            FilesPage(controller: controller, page: page, entry: entry)
        } else if let page = entry.page {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        if let failure = entry.failure {
                            InlineError(message: "Couldn't refresh: \(failure.message)") {
                                store.load(controller.key, root: controller.root, force: true)
                            }
                            .padding(.bottom, 12)
                        }
                        if controller.root == nil {
                            LocalFolderNotice(repository: controller.key.repository, window: controller.window)
                                .padding(.bottom, 16)
                        }
                        PullRequestHeader(controller: controller, page: page, entry: entry)
                        SegmentedTabs(items: [
                            SegmentItem(value: PullRequestWindowController.Section.overview, title: "Overview",
                                        count: nil),
                            SegmentItem(value: .files, title: "Files", count: page.changedFiles),
                            SegmentItem(value: .commits, title: "Commits", count: page.commits.count),
                            SegmentItem(value: .checks, title: "Checks", count: entry.shownChecks(page).count),
                        ], selection: Binding(get: { controller.section }, set: { section in
                            if section == .files { controller.reviewChanges() } else { controller.section = section }
                        }))
                        .padding(.vertical, 20)
                        switch controller.section {
                        case .overview: OverviewPage(controller: controller, page: page, entry: entry)
                        case .files: EmptyView()
                        case .commits: CommitsListPage(controller: controller, page: page)
                        case .checks: ChecksListPage(controller: controller, page: page, entry: entry)
                        }
                    }
                    .frame(maxWidth: 1100, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.top, 24)
                    .padding(.bottom, 40)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // A question asked (⌘I works from anywhere on the Overview): its answer shows over the comment box.
                .onChange(of: entry.ask.turn) { _, _ in
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.24)) {
                            proxy.scrollTo(AskClaudeCard.anchor, anchor: .bottom)
                        }
                    }
                }
            }
        } else if let issue = entry.issue {
            IssuePage(controller: controller, issue: issue)
        } else if let failure = entry.failure {
            UnavailablePage(controller: controller, failure: failure)
        } else {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Loading #\(controller.key.number)…").font(.studio(12)).foregroundStyle(StudioColors.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The pull request's header (board 1): its state, number, author and age; the title, with its pencil while it's open;
/// Copy Link beside the number; the branches with Copy, the base a picker while it's open; Check out and Review changes.
struct PullRequestHeader: View {
    @ObservedObject var controller: PullRequestWindowController
    let page: PullRequestPage.Page
    let entry: PullRequestStore.Entry
    @State private var editingTitle = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        statePill
                        HStack(spacing: 2) {
                            Text("#\(page.number)").font(.studioMono(12, .medium)).foregroundStyle(StudioColors.muted)
                            SidebarIconButton(icon: .copy, label: "Copy Link") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    "https://github.com/\(controller.key.repository)/pull/\(page.number)", forType: .string)
                            }
                        }
                        Text("opened \(StudioTime.ago(page.createdAt)) by \(page.author)")
                            .font(.studio(12))
                            .foregroundStyle(StudioColors.muted)
                    }
                    Group {
                        if editingTitle {
                            TitleEditor(controller: controller, page: page, entry: entry) { editingTitle = false }
                        } else {
                            HStack(alignment: .top, spacing: 6) {
                                Text(page.title)
                                    .font(.studio(22, .bold))
                                    .tracking(-0.22)
                                    .foregroundStyle(StudioColors.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                                if page.state == .open {
                                    // Centred on the title's first line.
                                    SmallIconButton(icon: .pencil, label: "Edit Title") { editingTitle = true }
                                        .padding(.top, 3)
                                }
                            }
                        }
                    }
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                    HStack(spacing: 6) {
                        Text("Merge \(page.commits.count) \(page.commits.count == 1 ? "commit" : "commits") into")
                        BaseBranchButton(controller: controller, page: page, entry: entry)
                        Text("from")
                        BranchChip(page.head, size: 11.5)
                        SidebarIconButton(icon: .copy, label: "Copy Branch Name") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(page.head, forType: .string)
                        }
                    }
                    .font(.studio(12.5))
                    .foregroundStyle(StudioColors.body)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    StudioButton(title: checkedOut ? "Checked out" : "Check out", icon: .download,
                                 busy: entry.busy.contains("checkout"),
                                 enabled: controller.root != nil && !checkedOut && page.state == .open) {
                        PullRequestStore.shared.perform(.checkout, key: controller.key, root: controller.root)
                    }
                    .help(controller.root == nil ? LocalFolderNotice.needs(controller.key.repository)
                          : "Check out the pull request's branch in your project")
                    StudioButton(title: "Review changes", hint: "⇧⌘R", style: .primary) { controller.reviewChanges() }
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                }
            }
            if let error = entry.errors["checkout"] ?? entry.errors["base"] { InlineError(message: error) }
        }
    }

    /// The project folder is on this pull request's branch already.
    private var checkedOut: Bool { controller.root.map { GitHead.branch(inFolder: $0) == page.head } ?? false }

    @ViewBuilder private var statePill: some View {
        switch page.state {
        case .merged: StatePill(text: "Merged", icon: .merge, tone: .coral, height: 24)
        case .closed: StatePill(text: "Closed", icon: .pullRequest, tone: .danger, height: 24)
        case .open:
            if page.isDraft {
                StatePill(text: "Draft", icon: .pullRequestDraft, tone: .neutral, height: 24)
            } else {
                StatePill(text: "Open", icon: .pullRequest, tone: .ok, height: 24)
            }
        }
    }
}

/// The canvas's status bar under a PR tab: the project's branch, the pull request's state, and Claude's.
struct PullRequestStatusBar: View {
    @ObservedObject var controller: PullRequestWindowController
    let entry: PullRequestStore.Entry
    @ObservedObject private var agents = AgentsActivity.shared

    var body: some View {
        HStack(spacing: 14) {
            if let root = controller.root, let branch = GitHead.branch(inFolder: root) {
                BranchChip(branch, size: 11)
            }
            if let page = entry.page, controller.section == .files {
                HStack(spacing: 5) {
                    StudioIcon(.pullRequest, size: 13)
                    Text(Self.reviewing(page: page, entry: entry, commit: controller.commit))
                }
            } else if let page = entry.page {
                let readiness = PullRequestPage.readiness(page, blockingThreads: entry.extras?.blocking.count ?? 0,
                                                          requiredApprovals: entry.extras?.requiredApprovals)
                HStack(spacing: 5) {
                    StudioIcon(.pullRequest, size: 13)
                    Text("#\(page.number) · \(Self.words(readiness.pill))")
                }
                .foregroundStyle(Self.isBlocked(readiness.pill) ? StudioColors.danger : StudioColors.muted)
            }
            Spacer(minLength: 8)
            claude
        }
        .font(.studio(11.5))
        .foregroundStyle(StudioColors.muted)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 26)
        .background(StudioColors.bar)
        .overlay(alignment: .top) { Rectangle().fill(StudioColors.line).frame(height: 1) }
    }

    @ViewBuilder private var claude: some View {
        if entry.read == .unavailable {
            Text("Claude Code isn't installed")
        } else if entry.ask.running {
            HStack(spacing: 6) {
                TealDot(size: 8)
                Text("Claude answering").foregroundStyle(StudioColors.tealInk)
            }
        } else if agents.isRunning {
            HStack(spacing: 6) {
                TealDot(size: 8)
                Text("Claude working").foregroundStyle(StudioColors.tealInk)
            }
        } else {
            HStack(spacing: 6) {
                CoralDot(size: 8)
                Text("Claude ready")
            }
        }
    }

    /// "Reviewing #51 · 1 pending comment", or the commit shown.
    static func reviewing(page: PullRequestPage.Page, entry: PullRequestStore.Entry, commit: String?) -> String {
        if let commit { return "Commit \(commit.prefix(7)) of #\(page.number)" }
        let pending = entry.extras?.pendingCount ?? 0
        guard pending > 0 else { return "Reviewing #\(page.number)" }
        return "Reviewing #\(page.number) · \(pending) pending \(pending == 1 ? "comment" : "comments")"
    }

    static func words(_ pill: PullRequestPage.Readiness.Pill) -> String {
        switch pill {
        case .ready: "ready to merge"
        case .pending: "waiting on checks or review"
        case .draft: "draft"
        case .merged: "merged"
        case .closed: "closed"
        case .blocked(let count): "\(count) blocking"
        }
    }

    static func isBlocked(_ pill: PullRequestPage.Readiness.Pill) -> Bool {
        if case .blocked = pill { return true }
        return false
    }
}

/// A number that's an issue, read-only: its state, title, author and description.
struct IssuePage: View {
    @ObservedObject var controller: PullRequestWindowController
    let issue: PullRequestActions.Issue

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    StatePill(text: issue.state == "OPEN" ? "Open" : "Closed", icon: .circle,
                              tone: issue.state == "OPEN" ? .ok : .neutral, height: 24)
                    Text("Issue #\(issue.number)").font(.studioMono(12, .medium)).foregroundStyle(StudioColors.muted)
                    Text("opened \(StudioTime.ago(issue.createdAt)) by \(issue.author)")
                        .font(.studio(12))
                        .foregroundStyle(StudioColors.muted)
                }
                Text(issue.title)
                    .font(.studio(22, .bold))
                    .foregroundStyle(StudioColors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                StudioCard {
                    StudioMarkdownView(markdown: issue.body.isEmpty ? "_No description._" : issue.body) {
                        PullRequestLinkRouter.open($0, from: controller)
                    }
                    .padding(16)
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Nothing to show: why, with Retry, and Close Tab.
struct UnavailablePage: View {
    @ObservedObject var controller: PullRequestWindowController
    let failure: PullRequests.Failure

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("#\(controller.key.number) isn't available").font(.studio(16, .semibold)).foregroundStyle(StudioColors.ink)
            Text(failure.message).font(.studio(12.5)).foregroundStyle(StudioColors.body).textSelection(.enabled)
            HStack(spacing: 8) {
                StudioButton(title: "Retry", icon: .refresh) {
                    PullRequestStore.shared.load(controller.key, root: controller.root, force: true)
                }
                StudioButton(title: "Close Tab", style: .quiet) { controller.window?.performClose(nil) }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
