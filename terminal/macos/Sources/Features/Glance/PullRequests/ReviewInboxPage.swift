import GlanceCore
import GlanceKit
import SwiftUI

/// The Review comments tab (board 4): the side bar column, the inbox, the Glance pane and the status bar. The threads
/// read now and every minute while the tab is open, in the side bar's one query.
struct ReviewInboxTabView: View {
    @ObservedObject var controller: ReviewInboxWindowController
    @ObservedObject private var model = PullRequestsModel.shared
    @ObservedObject private var tabSidebar = TabSidebarModel.shared

    var body: some View {
        let entry = model.entry(for: controller.repository)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if tabSidebar.isOpen {
                    SidebarColumn()
                }
                HSplitView {
                    ReviewInboxPage(controller: controller, entry: entry)
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
            ReviewInboxStatusBar(controller: controller, entry: entry)
        }
        .task(id: controller.repository) {
            // While the tab is open: now, then every minute (the model skips a read that's still fresh).
            await ActivePolling.run(every: 60) { model.load(controller.repository) }
        }
        .task { ReviewInboxStore.shared.checkClaude() }
    }
}

/// The canvas's status bar under the inbox: the project's branch, "6 unresolved · 2 blocking", and Claude's state, with
/// what a fix in this project is doing.
struct ReviewInboxStatusBar: View {
    @ObservedObject var controller: ReviewInboxWindowController
    let entry: PullRequestsModel.Entry
    @ObservedObject private var agents = AgentsActivity.shared
    @ObservedObject private var fixes = FixJobs.shared
    @ObservedObject private var inbox = ReviewInboxStore.shared

    var body: some View {
        HStack(spacing: 14) {
            if let root = controller.root, let branch = GitHead.branch(inFolder: root) {
                BranchChip(branch, size: 11)
            }
            if let board = entry.board, let reviews = entry.reviews {
                Text(ReviewInbox.statusLine(ReviewInbox.counts(board.waitingOnYou + board.yours,
                                                               threads: reviews.threads, viewer: reviews.viewer)))
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
        if inbox.claudeInstalled == false {
            Text("Claude Code isn't installed")
        } else if case .fixing(let activity)? = controller.root.flatMap({ fixes.jobs[$0]?.state }) {
            HStack(spacing: 6) {
                TealDot(size: 8)
                Text(activity.map(Self.saying) ?? "Claude working").foregroundStyle(StudioColors.tealInk)
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

    /// "Editing scripts/release.sh" → "Claude editing scripts/release.sh".
    static func saying(_ activity: String) -> String {
        "Claude " + activity.prefix(1).lowercased() + String(activity.dropFirst())
    }
}

/// The Review comments page (board 4): the filter's name and counts; then the threads by pull request, three of each
/// until "+ N more". It reads `PullRequestsModel`: the side bar's lists and their threads.
struct ReviewInboxPage: View {
    @ObservedObject var controller: ReviewInboxWindowController
    let entry: PullRequestsModel.Entry

    var body: some View {
        if let board = entry.board, let reviews = entry.reviews {
            inbox(board, reviews)
        } else if let failure = entry.failure {
            notice(failure.message)
        } else if entry.board != nil && !entry.loading {
            notice("Couldn't read the review threads.")
        } else {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Loading review comments…").font(.studio(12)).foregroundStyle(StudioColors.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func inbox(_ board: PullRequests.Board, _ reviews: ReviewThreads.BoardThreads) -> some View {
        let groups = ReviewInbox.groups(board.waitingOnYou + board.yours, threads: reviews.threads,
                                        filter: controller.filter, viewer: reviews.viewer)
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                if controller.root == nil {
                    LocalFolderNotice(repository: board.repository, window: controller.window)
                }
                if case .failed(let message)? = entry.failure {
                    InlineError(message: "Couldn't refresh: \(message)") {
                        PullRequestsModel.shared.load(controller.repository, force: true)
                    }
                }
                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(controller.filter.title)
                            .font(.studio(22, .bold))
                            .tracking(-0.22)
                            .foregroundStyle(StudioColors.ink)
                        Text(ReviewInbox.summaryLine(groups))
                            .font(.studio(12.5))
                            .foregroundStyle(StudioColors.muted)
                    }
                    Spacer(minLength: 0)
                    FixAllBlockingButton(controller: controller, board: board, reviews: reviews)
                }
                if groups.isEmpty {
                    Text(Self.empty(controller.filter))
                        .font(.studio(13))
                        .foregroundStyle(StudioColors.muted)
                        .padding(.top, 8)
                }
                ForEach(groups, id: \.pullRequest.number) { group in
                    InboxGroup(controller: controller, group: group, viewer: reviews.viewer,
                               repository: board.repository)
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// What an empty filter says.
    static func empty(_ filter: ReviewInbox.Filter) -> String {
        switch filter {
        case .unresolved: "No unresolved threads in the open pull requests."
        case .blocking: "Nothing blocks merging."
        case .waitingOnYou: "No thread is waiting on you."
        case .fromPeople: "No unresolved threads from people."
        case .fromBots: "No unresolved threads from review bots."
        case .resolved: "No resolved threads."
        }
    }

    /// Why there's no inbox, with Retry.
    private func notice(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Review comments aren't available").font(.studio(16, .semibold)).foregroundStyle(StudioColors.ink)
            Text(message).font(.studio(12.5)).foregroundStyle(StudioColors.body).textSelection(.enabled)
            StudioButton(title: "Retry", icon: .refresh) {
                PullRequestsModel.shared.load(controller.repository, force: true)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// One pull request's threads: its header (the icon; "#51 Release: …", which opens its tab; how many threads, or
/// "changes requested"), the first three threads, and "+ N more".
struct InboxGroup: View {
    @ObservedObject var controller: ReviewInboxWindowController
    let group: ReviewInbox.Group
    let viewer: String
    let repository: String

    var body: some View {
        let pullRequest = group.pullRequest
        let all = controller.expanded.contains(pullRequest.number)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                StudioIcon(pullRequest.isDraft ? .pullRequestDraft : .pullRequest, size: 14)
                    .foregroundStyle(pullRequest.isDraft ? StudioColors.muted : StudioColors.ok)
                Button {
                    PullRequestWindowController.open(repository: repository, number: pullRequest.number,
                                                     root: controller.root, from: controller.window)
                } label: {
                    Text("#\(pullRequest.number) \(pullRequest.title)")
                        .font(.studio(13, .semibold))
                        .foregroundStyle(StudioColors.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .help("Open #\(pullRequest.number)")
                if pullRequest.review == .changesRequested {
                    Text("· changes requested").font(.studio(12, .semibold)).foregroundStyle(StudioColors.danger)
                } else {
                    Text("· \(group.threads.count) \(group.threads.count == 1 ? "thread" : "threads")")
                        .font(.studio(12))
                        .foregroundStyle(StudioColors.muted)
                }
            }
            .padding(.top, 8)
            ForEach(all ? group.threads : Array(group.threads.prefix(3)), id: \.id) { thread in
                InboxThreadCard(controller: controller, thread: thread, pullRequest: pullRequest, viewer: viewer,
                                repository: repository)
            }
            if !all && group.threads.count > 3 {
                let more = group.threads.count - 3
                Button("+ \(more) more \(more == 1 ? "thread" : "threads") in #\(pullRequest.number)") {
                    controller.expanded.insert(pullRequest.number)
                }
                .buttonStyle(.plain)
                .font(.studio(12))
                .foregroundStyle(StudioColors.muted)
                .padding(.leading, 2)
            }
        }
    }
}

/// A thread in the inbox (board 4):
/// - its pill (Blocking, Optional, Waiting on you), `path:line` (opens the Files page there), who started it and how
///   many replied;
/// - its words: the first comment's, or, when it waits on you, the last comment with its author and age; with
///   replies, "Show all N replies" opens the whole conversation.
struct InboxThreadCard: View {
    @ObservedObject var controller: ReviewInboxWindowController
    let thread: ReviewThreads.Thread
    let pullRequest: PullRequests.PullRequest
    let viewer: String
    let repository: String
    @ObservedObject private var fixes = FixJobs.shared
    @ObservedObject private var inbox = ReviewInboxStore.shared
    @ObservedObject private var store = PullRequestStore.shared
    @ObservedObject private var drafts = ReplyDrafts.shared
    @ObservedObject private var writer = ReplyWriter.shared
    @State private var expanded = false

    var body: some View {
        let label = ReviewInbox.label(thread, viewer: viewer, author: pullRequest.author)
        let job = fixes.job(for: thread.id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                pill(label)
                Button { showInFiles() } label: {
                    Text(ReviewInbox.place(thread))
                        .font(.studioMono(12))
                        .foregroundStyle(StudioColors.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .help("Show It in the Files")
                if label != .waitingOnYou {
                    Text(byline)
                        .font(.studio(12))
                        .foregroundStyle(StudioColors.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let job { FixPill(job: job) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            if expanded {
                conversation
            } else {
                words(label)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
            if thread.comments.count > 1 {
                repliesToggle(thread.comments.count - 1)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
            actions(job, label: label)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(StudioColors.card))
        .overlay(alignment: .top) {
            // Board 4 lights a ready fix's card along its top edge.
            if Self.isReady(job) { Rectangle().fill(StudioColors.rim).frame(height: 1).padding(.horizontal, 10) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Self.isReady(job) ? StudioColors.line3 : StudioColors.line, lineWidth: 1))
    }

    private var key: PullRequestStore.Key { PullRequestStore.Key(repository: repository, number: pullRequest.number) }
    private var replyName: String { ReviewInboxStore.Action.reply(threadID: thread.id, body: "").name }
    private var wontFixName: String { ReviewInboxStore.Action.wontFix(threadID: thread.id).name }
    private var resolveName: String { ReviewInboxStore.Action.resolve(threadID: thread.id).name }

    /// The last failed write on this thread, or its pull request's failed check-out.
    private var error: String? {
        inbox.errors[replyName] ?? inbox.errors[wontFixName] ?? inbox.errors[resolveName]
            ?? store.entry(key).errors["checkout"]
    }

    static func isReady(_ job: FixJobs.Job?) -> Bool {
        if case .ready? = job?.state { return true }
        return false
    }

    /// By state: the fix (its panel draws its own rule; Fix ready sits straight under the words); the reply field;
    /// Claude's drafted reply; or the actions (the canvas's row: Reply and Fix with Claude, then Won't fix and Resolve),
    /// Unresolve on a resolved thread.
    @ViewBuilder private func actions(_ job: FixJobs.Job?, label: ReviewInbox.Label?) -> some View {
        let actionable = thread.isResolved ? thread.viewerCanUnresolve : thread.viewerCanReply || thread.viewerCanResolve
        let draft = label == .waitingOnYou && thread.viewerCanReply ? drafts.state(draftID) : nil
        if let job {
            FixPanel(job: job, retry: job.isSuggestion ? nil : { fix() })
        } else if controller.replying == thread.id {
            replyField
        } else if let draft, draft != .discarded {
            draftBlock(draft)
        } else if actionable {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if thread.isResolved {
                        Spacer(minLength: 0)
                        StudioButton(title: "Unresolve", style: .quiet, busy: inbox.busy.contains(resolveName)) {
                            perform(.unresolve(threadID: thread.id))
                        }
                    } else {
                        if thread.viewerCanReply {
                            StudioButton(title: "Reply", icon: .reply) {
                                controller.reply = ""
                                controller.replying = thread.id
                            }
                        }
                        fixButton
                        if label == .waitingOnYou && thread.viewerCanReply && (draft == nil || draft == .discarded)
                            && inbox.claudeInstalled != false {
                            StudioButton(title: "Draft a reply", style: .quiet) {
                                ReplyDrafts.shared.request(draftRequest)
                            }
                            .help("Claude drafts a reply for you to edit and send")
                        }
                        Spacer(minLength: 0)
                        if thread.viewerCanReply && thread.viewerCanResolve {
                            StudioButton(title: "Won't fix", style: .quiet, busy: inbox.busy.contains(wontFixName)) {
                                perform(.wontFix(threadID: thread.id))
                            }
                            .help("Replies “Won't fix.” and resolves the thread")
                        }
                        if thread.viewerCanResolve {
                            StudioButton(title: "Resolve", icon: .check, style: .quiet,
                                         busy: inbox.busy.contains(resolveName)) {
                                perform(.resolve(threadID: thread.id))
                            }
                        }
                    }
                }
                if let error { InlineError(message: error) }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .overlay(alignment: .top) { Rectangle().fill(StudioColors.line2).frame(height: 1) }
        }
    }

    /// Fix with Claude, with the dot (the page's glow ring is Fix all blocking). On another branch, "Check out #N"
    /// comes first.
    @ViewBuilder private var fixButton: some View {
        if let root = controller.root {
            if GitHead.branch(inFolder: root) != pullRequest.head {
                StudioButton(title: "Check out #\(pullRequest.number)", icon: .download,
                             busy: store.entry(key).busy.contains("checkout")) {
                    PullRequestStore.shared.perform(.checkout, key: key, root: root)
                }
                .help("Fixes happen in your project, on the pull request's branch")
            } else {
                let claude = inbox.claudeInstalled != false
                let busy = fixes.isBusy(root: root)
                DotButton(title: "Fix with Claude", enabled: claude && !busy) { fix() }
                    .help(!claude ? "Install Claude Code to fix with Claude"
                          : busy ? "A fix is under way in this project"
                          : "Claude changes your working tree; you accept or reject")
            }
        } else {
            DotButton(title: "Fix with Claude", enabled: false) {}
                .help(LocalFolderNotice.needs(repository))
        }
    }

    /// The comment a draft answers: the thread's last.
    private var draftID: String { thread.comments.last?.id ?? thread.id }

    private var draftRequest: ReplyDrafts.Request {
        ReplyDrafts.Request(thread: thread, number: pullRequest.number, title: pullRequest.title,
                            repository: repository, viewer: viewer, root: controller.root)
    }

    /// Claude's drafted reply (board 4): the text to edit, "Claude drafted this reply", Discard, Reply ⌘↩ and Reply & fix
    /// with Claude. While Claude drafts, the field says so; a failed draft says why, with Retry.
    private func draftBlock(_ state: ReplyDrafts.State) -> some View {
        let ready: Bool
        if case .ready = state { ready = true } else { ready = false }
        let text = drafts.text(draftID).trimmingCharacters(in: .whitespacesAndNewlines)
        let claude = inbox.claudeInstalled != false
        let busy = controller.root.map { fixes.isBusy(root: $0) } ?? false
        let onBranch = controller.root.map { GitHead.branch(inFolder: $0) == pullRequest.head } ?? false
        return VStack(alignment: .leading, spacing: 8) {
            switch state {
            case .queued, .drafting:
                HStack(spacing: 8) {
                    Spinner(size: 13)
                    Text("Claude is drafting a reply…").font(.studio(12.5)).foregroundStyle(StudioColors.muted)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.background))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(StudioColors.line3, lineWidth: 1))
            case .ready:
                StudioTextEditor(placeholder: "Reply to \(thread.comments.last?.author ?? "the thread")…",
                                 text: Binding(get: { drafts.text(draftID) },
                                               set: { drafts.setText($0, for: draftID) }),
                                 minHeight: 60)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.background))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(StudioColors.coral, lineWidth: 1))
            case .failed(let message):
                InlineError(message: "Claude couldn't draft a reply: \(message)") {
                    ReplyDrafts.shared.retry(draftRequest)
                }
            case .discarded:
                EmptyView()
            }
            HStack(spacing: 8) {
                if ready {
                    HStack(spacing: 6) {
                        CoralDot(size: 8)
                        Text("Claude drafted this reply")
                    }
                    .font(.studio(11.5))
                    .foregroundStyle(StudioColors.muted)
                }
                Spacer(minLength: 0)
                StudioButton(title: "Discard", style: .quiet) { ReplyDrafts.shared.discard(draftID) }
                StudioButton(title: "Reply", hint: "⌘↩", busy: inbox.busy.contains(replyName),
                             enabled: ready && !text.isEmpty) {
                    sendDraft(text, fix: false)
                }
                .keyboardShortcut(.return, modifiers: .command)
                StudioButton(title: "Reply & fix with Claude", busy: inbox.busy.contains(replyName),
                             enabled: ready && !text.isEmpty && claude && !busy && controller.root != nil) {
                    sendDraft(text, fix: true)
                }
                .help(controller.root == nil ? LocalFolderNotice.needs(repository)
                      : !claude ? "Install Claude Code to fix with Claude"
                      : busy ? "A fix is under way in this project"
                      : onBranch ? "Posts the reply, then Claude fixes the thread with it in mind"
                      : "Posts the reply, checks out #\(pullRequest.number), then Claude fixes the thread")
            }
            if let error { InlineError(message: error) }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .overlay(alignment: .top) { Rectangle().fill(StudioColors.line2).frame(height: 1) }
    }

    /// Reply ⌘↩ posts the draft as the user's reply. Reply & fix then sends the thread, with that answer, to the
    /// project's Claude, checking the pull request out first when the project is on another branch.
    private func sendDraft(_ text: String, fix: Bool) {
        let id = draftID
        let answered = ReviewInbox.replied(thread, by: viewer, body: text)
        let root = controller.root, key = self.key, window = controller.window
        let number = pullRequest.number, title = pullRequest.title, head = pullRequest.head
        perform(.reply(threadID: thread.id, body: text)) {
            ReplyDrafts.shared.sent(id)
            guard fix, let root else { return }
            let start = {
                FixJobs.shared.dismiss(root: root)
                FixJobs.shared.fix([answered], number: number, title: title, key: key, root: root, window: window)
            }
            if GitHead.branch(inFolder: root) == head {
                start()
            } else {
                PullRequestStore.shared.perform(.checkout, key: key, root: root, then: start)
            }
        }
    }

    /// The reply field (the canvas's textarea, coral while open): Write with Claude writes the reply (from what's typed,
    /// when there's something), Reply ⌘↩ posts at once, Cancel (Esc) closes it (stopping Claude first).
    private var replyField: some View {
        let text = controller.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let writing = writer.writing.contains(thread.id)
        return VStack(alignment: .leading, spacing: 8) {
            StudioTextEditor(placeholder: "Reply to \(thread.comments.last?.author ?? "the thread")…",
                             text: $controller.reply, minHeight: 60)
                .disabled(writing)
                .opacity(writing ? 0.55 : 1)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.background))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(StudioColors.coral, lineWidth: 1))
            if let error = inbox.errors[replyName] ?? writer.errors[thread.id] { InlineError(message: error) }
            HStack(spacing: 8) {
                if writing {
                    HStack(spacing: 8) {
                        Spinner(size: 13)
                        Text("Claude is writing your reply…").font(.studio(12.5)).foregroundStyle(StudioColors.muted)
                    }
                    StudioButton(title: "Stop", style: .quiet) { writer.stop(thread.id) }
                } else if inbox.claudeInstalled != false {
                    DotButton(title: "Write with Claude") { writeWithClaude() }
                        .help(text.isEmpty ? "Claude drafts a reply for you to edit and send"
                              : "Claude writes the reply from what you typed, for you to edit and send")
                }
                Spacer(minLength: 0)
                StudioButton(title: "Cancel", hint: "Esc", style: .quiet) {
                    writer.stop(thread.id)
                    writer.clearError(thread.id)
                    controller.replying = nil
                }
                    .keyboardShortcut(.escape, modifiers: [])
                StudioButton(title: "Reply", hint: "⌘↩", busy: inbox.busy.contains(replyName),
                             enabled: !text.isEmpty && !writing) {
                    perform(.reply(threadID: thread.id, body: text)) {
                        controller.replying = nil
                        controller.reply = ""
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .overlay(alignment: .top) { Rectangle().fill(StudioColors.line2).frame(height: 1) }
    }

    /// Write with Claude: the reply, from the thread and what's in the field, replaces the field's text.
    private func writeWithClaude() {
        let id = thread.id, controller = self.controller
        ReplyWriter.shared.write(draftRequest, notes: controller.reply) { reply in
            guard controller.replying == id else { return }
            controller.reply = reply
        }
    }

    /// Fix with Claude, or Retry after a failed fix: this thread alone, routed to the project's Claude.
    private func fix() {
        guard let root = controller.root else { return }
        FixJobs.shared.dismiss(root: root)
        FixJobs.shared.fix([thread], number: pullRequest.number, title: pullRequest.title, key: key,
                           root: root, window: controller.window)
    }

    private func perform(_ action: ReviewInboxStore.Action, then done: (() -> Void)? = nil) {
        ReviewInboxStore.shared.perform(action, key: key, then: done)
    }

    /// "claude · 1 reply", and who resolved it.
    private var byline: String {
        let line = ReviewInbox.byline(thread)
        guard thread.isResolved, let by = thread.resolvedBy else { return line }
        return line + " · resolved by \(by)"
    }

    @ViewBuilder private func pill(_ label: ReviewInbox.Label?) -> some View {
        if let label {
            switch label {
            case .blocking: StatePill(text: "Blocking", icon: .alert, tone: .danger, height: 20)
            case .optional: StatePill(text: "Optional", tone: .neutral, height: 20)
            case .waitingOnYou: StatePill(text: "Waiting on you", tone: .amber, height: 20)
            }
        }
    }

    @ViewBuilder private func words(_ label: ReviewInbox.Label?) -> some View {
        if label == .waitingOnYou, let last = thread.comments.last {
            HStack(alignment: .top, spacing: 10) {
                Avatar(login: last.author, size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(last.author).font(.studio(13, .semibold)).foregroundStyle(StudioColors.ink)
                        Text("· \(StudioTime.ago(last.createdAt))").font(.studio(12)).foregroundStyle(StudioColors.muted)
                    }
                    CommentText(text: last.body) { open($0) }
                }
            }
        } else if let first = thread.comments.first {
            CommentText(text: first.body) { open($0) }
        }
    }

    /// The whole thread, oldest first: who said what, and when.
    private var conversation: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(thread.comments.enumerated()), id: \.offset) { index, comment in
                if index > 0 { Rectangle().fill(StudioColors.line2).frame(height: 1).padding(.horizontal, 14) }
                ReplyRow(comment: comment) { open($0) }
            }
        }
    }

    /// "Show all 3 replies" / "Hide replies".
    private func repliesToggle(_ count: Int) -> some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 5) {
                StudioIcon(expanded ? .chevronUp : .chevronDown, size: 12)
                Text(expanded ? "Hide replies" : count == 1 ? "Show 1 reply" : "Show all \(count) replies")
            }
            .font(.studio(12, .medium))
            .foregroundStyle(StudioColors.coralInk)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(expanded ? "expanded" : "collapsed")
    }

    /// The thread's line on the pull request's Files page, in its tab.
    private func showInFiles() {
        let tab = PullRequestWindowController.open(repository: repository, number: pullRequest.number,
                                                   root: controller.root, from: controller.window)
        tab?.reviewChanges(path: thread.path,
                           focus: thread.line.map { ReviewThreads.Anchor(side: thread.side, line: $0) })
    }

    private func open(_ url: URL) {
        PullRequestLinkRouter.open(url, repository: repository, root: controller.root, from: controller.window)
    }
}
