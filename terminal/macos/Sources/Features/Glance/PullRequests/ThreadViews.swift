import GlanceCore
import SwiftUI

/// How the Files page names where a thread, or a new comment, is.
enum ThreadText {
    /// "line 123", "lines 117–119", "the file"; an outdated thread's original line.
    static func place(_ thread: ReviewThreads.Thread) -> String {
        if thread.isFileLevel { return "the file" }
        guard let line = thread.line ?? thread.originalLine else { return "" }
        if let start = thread.startLine, start != line { return "lines \(start)–\(line)" }
        return "line \(line)"
    }

    /// "Comment on line 119", "Comment on lines 117–119".
    static func composing(start: ReviewThreads.Anchor?, end: ReviewThreads.Anchor) -> String {
        guard let start, start != end else { return "Comment on line \(end.line)" }
        return "Comment on lines \(start.line)–\(end.line)"
    }
}

extension View {
    /// The canvas's block under a diff line: set in 70 pt from the left, on the page's background between hairlines.
    func inlineBlock() -> some View {
        padding(.leading, 70)
            .padding(.trailing, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StudioColors.background)
            .overlay(alignment: .top) { Rectangle().fill(StudioColors.line2).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(StudioColors.line2).frame(height: 1) }
    }
}

/// The threads under a diff line (board 2).
struct InlineThreads: View {
    @ObservedObject var controller: PullRequestWindowController
    let threads: [ReviewThreads.Thread]
    let entry: PullRequestStore.Entry
    /// The file they're on, for a suggestion's lines.
    let file: PullRequestDiff.File?
    let page: PullRequestPage.Page
    /// The page's one glow ring: this thread's Fix with Claude wears it.
    let glowThreadID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(threads, id: \.id) { thread in
                ThreadView(controller: controller, thread: thread, entry: entry, file: file, page: page,
                           glow: thread.id == glowThreadID)
            }
        }
        .inlineBlock()
    }
}

/// One thread, as its state draws it:
/// - the viewer's pending one as the Pending card;
/// - a resolved one folded to its dashed row (a click opens it);
/// - an open one as the thread card.
struct ThreadView: View {
    @ObservedObject var controller: PullRequestWindowController
    let thread: ReviewThreads.Thread
    let entry: PullRequestStore.Entry
    let file: PullRequestDiff.File?
    let page: PullRequestPage.Page
    var glow = false
    @State private var opened = false

    var body: some View {
        if thread.isPending {
            PendingCard(controller: controller, thread: thread, entry: entry)
        } else if thread.isResolved && !opened {
            ResolvedRow(controller: controller, thread: thread, entry: entry) { opened = true }
        } else {
            ThreadCard(controller: controller, thread: thread, entry: entry, file: file, page: page, glow: glow,
                       fold: thread.isResolved ? { opened = false } : nil)
        }
    }
}

/// An open thread (board 2):
/// - the first comment with its author, Blocking or Optional, where and when, and its words (a suggestion as
///   "Suggested change");
/// - the replies;
/// - the reply field;
/// - Resolve, or Unresolve on a resolved thread opened from its row.
private struct ThreadCard: View {
    @ObservedObject var controller: PullRequestWindowController
    let thread: ReviewThreads.Thread
    let entry: PullRequestStore.Entry
    let file: PullRequestDiff.File?
    let page: PullRequestPage.Page
    /// The file's first open thread: its Fix with Claude wears the page's glow ring.
    let glow: Bool
    /// Folds a resolved thread opened from its row.
    let fold: (() -> Void)?
    @ObservedObject private var fixes = FixJobs.shared
    @ObservedObject private var writer = ReplyWriter.shared
    @State private var reply = ""

    var body: some View {
        let replyAction = PullRequestStore.ReviewAction.reply(threadID: thread.id, body: reply)
        let resolveAction: PullRequestStore.ReviewAction = thread.isResolved
            ? .unresolve(threadID: thread.id) : .resolve(threadID: thread.id)
        VStack(alignment: .leading, spacing: 0) {
            if let first = thread.comments.first {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Avatar(login: first.author, size: 20)
                        Text(first.author).font(.studio(12, .semibold)).foregroundStyle(StudioColors.ink)
                        SeverityPill(severity: ReviewThreads.severity(thread))
                        if thread.isOutdated { StatePill(text: "Outdated", tone: .neutral, height: 18) }
                        Text([ThreadText.place(thread), StudioTime.ago(first.createdAt)].filter { !$0.isEmpty }
                            .joined(separator: " · "))
                            .font(.studio(12))
                            .foregroundStyle(StudioColors.muted)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if let job = fixes.job(for: thread.id) { FixPill(job: job) }
                        if let fold { SmallIconButton(icon: .chevronUp, label: "Fold the Thread", action: fold) }
                    }
                    CommentText(text: first.body, original: original) { PullRequestLinkRouter.open($0, from: controller) }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 12)
            }
            ForEach(thread.comments.dropFirst(), id: \.id) { comment in
                Rectangle().fill(StudioColors.line2).frame(height: 1)
                ReplyRow(comment: comment) { PullRequestLinkRouter.open($0, from: controller) }
            }
            if let job = fixes.job(for: thread.id) {
                // The panel draws its own rule: Fix ready sits straight under the comment.
                FixPanel(job: job, retry: job.isSuggestion ? nil : { fixAgain() })
            } else if thread.viewerCanReply || thread.viewerCanResolve || thread.viewerCanUnresolve {
                Rectangle().fill(StudioColors.line2).frame(height: 1)
                VStack(alignment: .leading, spacing: 10) {
                    if thread.viewerCanReply {
                        ReplyField(text: $reply, busy: entry.busy.contains(replyAction.name),
                                   writing: writer.writing.contains(thread.id),
                                   write: entry.read == .unavailable ? nil : { writeWithClaude() },
                                   stop: { writer.stop(thread.id) }) {
                            PullRequestStore.shared.review(replyAction, key: controller.key) { reply = "" }
                        }
                    }
                    HStack(spacing: 8) {
                        if page.state == .open && !thread.isResolved {
                            FixActions(controller: controller, thread: thread, page: page, entry: entry, glow: glow,
                                       original: original)
                        }
                        Spacer(minLength: 0)
                        if thread.isResolved ? thread.viewerCanUnresolve : thread.viewerCanResolve {
                            StudioButton(title: thread.isResolved ? "Unresolve" : "Resolve",
                                         icon: thread.isResolved ? nil : .check, style: .quiet,
                                         busy: entry.busy.contains(resolveAction.name)) {
                                PullRequestStore.shared.review(resolveAction, key: controller.key)
                            }
                        }
                    }
                    if let error = entry.errors[replyAction.name] ?? entry.errors[resolveAction.name]
                        ?? writer.errors[thread.id] {
                        InlineError(message: error)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StudioColors.card))
        .overlay(alignment: .top) {
            if fixReady { Rectangle().fill(StudioColors.rim).frame(height: 1).padding(.horizontal, 10) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(StudioColors.line3, lineWidth: 1))
    }

    /// Write with Claude: the reply, from the thread and what's in the field, replaces the field's text.
    private func writeWithClaude() {
        let request = ReplyDrafts.Request(thread: thread, number: controller.key.number, title: page.title,
                                          repository: controller.key.repository,
                                          viewer: entry.extras?.viewer ?? "the user", root: controller.root)
        let text = $reply
        ReplyWriter.shared.write(request, notes: reply) { text.wrappedValue = $0 }
    }

    /// Retry: the same fix, again.
    private func fixAgain() {
        guard let root = controller.root else { return }
        FixJobs.shared.dismiss(root: root)
        FixJobs.shared.fix([thread], page: page, key: controller.key, root: root, window: controller.window)
    }

    private var fixReady: Bool {
        if case .ready? = fixes.job(for: thread.id)?.state { return true }
        return false
    }

    /// The lines a suggestion would replace: the thread's lines on the new side.
    private var original: [String] {
        guard let file, let line = thread.line, thread.side == .right else { return [] }
        return PullRequestDiff.newLines(file, from: thread.startLine ?? line, to: line)
    }
}

/// A resolved thread, folded (board 2): who resolved it, whose it was and where, and Unresolve. The words open it.
private struct ResolvedRow: View {
    @ObservedObject var controller: PullRequestWindowController
    let thread: ReviewThreads.Thread
    let entry: PullRequestStore.Entry
    let open: () -> Void

    var body: some View {
        let action = PullRequestStore.ReviewAction.unresolve(threadID: thread.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                StudioIcon(.check, size: 14, weight: 2.2).foregroundStyle(StudioColors.ok)
                Button(action: open) {
                    Text(words).lineLimit(1).truncationMode(.tail).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show the Thread")
                Spacer(minLength: 8)
                if thread.viewerCanUnresolve {
                    StudioButton(title: "Unresolve", style: .quiet, busy: entry.busy.contains(action.name)) {
                        PullRequestStore.shared.review(action, key: controller.key)
                    }
                }
            }
            .font(.studio(12.5))
            .foregroundStyle(StudioColors.muted)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: 720, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(StudioColors.line3, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            if let error = entry.errors[action.name] { InlineError(message: error) }
        }
    }

    /// "Resolved by you · Claude Code Review on line 123".
    private var words: String {
        let viewer = entry.extras?.viewer
        let resolver = thread.resolvedBy.map { $0 == viewer ? "you" : $0 } ?? "someone"
        let place = ThreadText.place(thread)
        return "Resolved by \(resolver) · \(thread.comments.first?.author ?? "")" + (place.isEmpty ? "" : " on \(place)")
    }
}

/// The viewer's pending thread (board 2): only they see it until the review is submitted.
private struct PendingCard: View {
    @ObservedObject var controller: PullRequestWindowController
    let thread: ReviewThreads.Thread
    let entry: PullRequestStore.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(thread.comments, id: \.id) { comment in
                PendingComment(controller: controller, comment: comment, place: ThreadText.place(thread), entry: entry)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 720, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StudioColors.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(StudioColors.line3, lineWidth: 1))
    }
}

/// One pending comment: You, Pending, the line, edit and delete; its words, or the field while it's edited.
private struct PendingComment: View {
    @ObservedObject var controller: PullRequestWindowController
    let comment: ReviewThreads.Comment
    let place: String
    let entry: PullRequestStore.Entry
    @State private var editing: String?

    var body: some View {
        let edit = PullRequestStore.ReviewAction.edit(commentID: comment.id, body: editing ?? "")
        let delete = PullRequestStore.ReviewAction.delete(commentID: comment.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Avatar(login: comment.author, size: 20)
                Text("You").font(.studio(12, .semibold)).foregroundStyle(StudioColors.ink)
                StatePill(text: "Pending", tone: .amber, height: 18)
                Text(place).font(.studio(12)).foregroundStyle(StudioColors.muted)
                Spacer(minLength: 0)
                if comment.viewerCanUpdate && editing == nil {
                    SmallIconButton(icon: .pencil, label: "Edit Comment") { editing = comment.body }
                }
                if comment.viewerCanDelete {
                    SmallIconButton(icon: .trash, label: "Delete Comment", busy: entry.busy.contains(delete.name)) {
                        PullRequestStore.shared.review(delete, key: controller.key)
                    }
                }
            }
            if editing != nil {
                VStack(alignment: .trailing, spacing: 8) {
                    StudioTextEditor(placeholder: "Leave a comment",
                                     text: Binding(get: { editing ?? "" }, set: { editing = $0 }), minHeight: 60)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.background))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(StudioColors.line3, lineWidth: 1))
                    HStack(spacing: 8) {
                        StudioButton(title: "Cancel", style: .quiet) { editing = nil }
                        StudioButton(title: "Save", style: .primary, busy: entry.busy.contains(edit.name),
                                     enabled: !(editing ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                            PullRequestStore.shared.review(edit, key: controller.key) { editing = nil }
                        }
                    }
                }
            } else {
                CommentText(text: comment.body) { PullRequestLinkRouter.open($0, from: controller) }
            }
            if let error = entry.errors[edit.name] ?? entry.errors[delete.name] { InlineError(message: error) }
        }
    }
}

/// A reply: its author and age, Pending while it waits in the viewer's review, and its words.
struct ReplyRow: View {
    let comment: ReviewThreads.Comment
    let open: (URL) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Avatar(login: comment.author, size: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(comment.author).font(.studio(12.5, .semibold)).foregroundStyle(StudioColors.ink)
                    Text("· \(StudioTime.ago(comment.createdAt))").font(.studio(12.5)).foregroundStyle(StudioColors.muted)
                    if comment.isPending { StatePill(text: "Pending", tone: .amber, height: 18) }
                }
                CommentText(text: comment.body, size: 12.5, open: open)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// A thread's reply on its own, for where a thread isn't drawn whole (a reply to an earlier review's thread on the
/// Overview): the field, Write with Claude and Reply, with their error.
struct ThreadReplyBox: View {
    @ObservedObject var controller: PullRequestWindowController
    let thread: ReviewThreads.Thread
    let entry: PullRequestStore.Entry
    let page: PullRequestPage.Page
    @ObservedObject private var writer = ReplyWriter.shared
    @State private var reply = ""

    var body: some View {
        let replyAction = PullRequestStore.ReviewAction.reply(threadID: thread.id, body: reply)
        VStack(alignment: .leading, spacing: 8) {
            ReplyField(text: $reply, busy: entry.busy.contains(replyAction.name),
                       writing: writer.writing.contains(thread.id),
                       write: entry.read == .unavailable ? nil : { writeWithClaude() },
                       stop: { writer.stop(thread.id) }) {
                PullRequestStore.shared.review(replyAction, key: controller.key) { reply = "" }
            }
            if let error = entry.errors[replyAction.name] ?? writer.errors[thread.id] {
                InlineError(message: error)
            }
        }
    }

    private func writeWithClaude() {
        let request = ReplyDrafts.Request(thread: thread, number: controller.key.number, title: page.title,
                                          repository: controller.key.repository,
                                          viewer: entry.extras?.viewer ?? "the user", root: controller.root)
        let text = $reply
        ReplyWriter.shared.write(request, notes: reply) { text.wrappedValue = $0 }
    }
}

/// The thread's reply field (it posts at once): a line that grows, Write with Claude (it writes the reply, from what's
/// typed when there's something), and Reply once there's something to send.
private struct ReplyField: View {
    @Binding var text: String
    let busy: Bool
    var writing = false
    /// Nil without Claude Code.
    var write: (() -> Void)?
    var stop: () -> Void = {}
    let send: () -> Void

    var body: some View {
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack(alignment: .bottom, spacing: 8) {
            TextField(writing ? "Claude is writing your reply…" : "Reply…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.studio(12.5))
                .foregroundStyle(StudioColors.ink)
                .lineLimit(1...6)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(minHeight: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.background))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(StudioColors.line3, lineWidth: 1))
                .onSubmit { if !empty && !writing { send() } }
                .disabled(writing)
                .opacity(writing ? 0.55 : 1)
                .accessibilityLabel("Reply")
            if writing {
                HStack(spacing: 8) {
                    Spinner(size: 13)
                    StudioButton(title: "Stop", style: .quiet, action: stop)
                }
                .frame(height: 32)
            } else {
                if let write {
                    DotButton(title: "Write with Claude", action: write)
                        .help(empty ? "Claude drafts a reply for you to edit and send"
                              : "Claude writes the reply from what you typed, for you to edit and send")
                        .padding(.bottom, 1)
                }
                if !empty {
                    StudioButton(title: "Reply", busy: busy, action: send)
                }
            }
        }
    }
}

/// A new comment on a line or a range (board 2), joining the viewer's pending review: the field, Cancel (Esc) and Add
/// review comment ⌘↩.
struct CommentComposer: View {
    let title: String
    @Binding var text: String
    let busy: Bool
    let error: String?
    let cancel: () -> Void
    let add: () -> Void
    /// The switch, when there is one: Comment | Ask Claude on the Files page, nothing on read-only diffs (Ask only).
    var mode: Binding<ComposeMode>? = nil
    /// Ask only: a read-only diff's box.
    var asksOnly = false
    var canAsk = false
    var ask: () -> Void = {}

    var body: some View {
        let asking = asksOnly || mode?.wrappedValue == .ask
        let filled = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let mode { ComposeModePicker(mode: mode, canAsk: canAsk) }
                Text(title).font(.studio(12, .semibold)).foregroundStyle(StudioColors.muted)
            }
            StudioTextEditor(placeholder: asking ? "Ask about these lines" : "Leave a comment", text: $text, minHeight: 72)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.background))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(StudioColors.line3, lineWidth: 1))
            if let error, !asking { InlineError(message: error) }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                StudioButton(title: "Cancel", style: .quiet, action: cancel)
                    .keyboardShortcut(.escape, modifiers: [])
                if asking {
                    StudioButton(title: "Ask Claude", hint: "⌘↩", style: .primary, enabled: canAsk && filled, action: ask)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help(canAsk ? "Ask Claude about these lines" : "Install Claude Code to ask Claude")
                } else {
                    StudioButton(title: "Add review comment", hint: "⌘↩", style: .primary, busy: busy,
                                 enabled: filled, action: add)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 720, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StudioColors.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(StudioColors.line3, lineWidth: 1))
    }
}

/// Blocking (red, with the alert) or Optional (muted); nothing for an ordinary thread.
private struct SeverityPill: View {
    let severity: ReviewThreads.Severity

    var body: some View {
        switch severity {
        case .blocking: StatePill(text: "Blocking", icon: .alert, tone: .danger, height: 18)
        case .optional: StatePill(text: "Optional", tone: .neutral, height: 18)
        case .normal: EmptyView()
        }
    }
}

/// The canvas's 24 pt icon button: a 13 pt icon that lights under the pointer.
struct SmallIconButton: View {
    let icon: StudioIcons.Name
    let label: String
    var busy = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    StudioIcon(icon, size: 13)
                }
            }
            .foregroundStyle(hovering ? StudioColors.ink : StudioColors.muted)
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? StudioColors.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A comment's words in Markdown. A ```suggestion block becomes "Suggested change": the lines it replaces (−) and the
/// ones it puts in (+).
struct CommentText: View {
    let text: String
    var size: CGFloat = 13
    /// The lines a suggestion replaces.
    var original: [String] = []
    let open: (URL) -> Void

    var body: some View {
        if let suggestion = ReviewThreads.suggestion(in: text) {
            VStack(alignment: .leading, spacing: 8) {
                if !suggestion.before.isEmpty { StudioMarkdownView(markdown: suggestion.before, size: size, open: open) }
                SuggestionBlock(removed: original, added: suggestion.lines)
                if !suggestion.after.isEmpty { StudioMarkdownView(markdown: suggestion.after, size: size, open: open) }
            }
        } else {
            StudioMarkdownView(markdown: text, size: size, open: open)
        }
    }
}

/// "Suggested change": the lines it replaces on red with −, the lines it puts in on green with +.
private struct SuggestionBlock: View {
    let removed: [String]
    let added: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Suggested change")
                .font(.studio(11, .semibold))
                .foregroundStyle(StudioColors.muted)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StudioColors.field)
            ForEach(Array(removed.enumerated()), id: \.offset) { _, line in
                row("−", line, ink: StudioColors.danger, fill: StudioColors.dangerFill)
            }
            ForEach(Array(added.enumerated()), id: \.offset) { _, line in
                row("+", line, ink: StudioColors.ok, fill: StudioColors.okFill)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(StudioColors.line, lineWidth: 1))
    }

    private func row(_ sign: String, _ text: String, ink: Color, fill: Color) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(sign).foregroundStyle(ink).frame(width: 22)
            Text(text.isEmpty ? " " : text)
                .foregroundStyle(StudioColors.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.studioMono(11.5))
        .padding(.vertical, 1)
        .background(fill)
    }
}
