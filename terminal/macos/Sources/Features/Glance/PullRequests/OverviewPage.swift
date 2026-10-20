import AppKit
import GlanceCore
import SwiftUI

/// The Overview page (board 1): Claude's read, the description, the activity oldest first, what was asked of Claude and
/// the comment box, beside merge readiness, reviewers, checks and details.
struct OverviewPage: View {
    @ObservedObject var controller: PullRequestWindowController
    let page: PullRequestPage.Page
    let entry: PullRequestStore.Entry

    var body: some View {
        OverviewColumns {
            mainColumn
            OverviewSideColumn(controller: controller, page: page, entry: entry)
        }
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            ClaudeReadCard(controller: controller, read: entry.read)
            DescriptionCard(controller: controller, page: page, entry: entry)
            ActivityList(controller: controller, page: page, entry: entry)
            AskClaudeCard(controller: controller, ask: entry.ask)
            Composer(controller: controller, page: page, entry: entry)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The description (board 1's card): its author and age, the body as Markdown, and the pencil to edit it in place,
/// rendered as it's typed (`LiveMarkdownEditor`); ⌘⏎ saves.
struct DescriptionCard: View {
    @ObservedObject var controller: PullRequestWindowController
    let page: PullRequestPage.Page
    let entry: PullRequestStore.Entry
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Avatar(login: page.author, size: 22)
                    Text(page.author).font(.studio(12, .semibold)).foregroundStyle(StudioColors.ink)
                    Text("wrote · \(StudioTime.ago(page.createdAt))").font(.studio(12)).foregroundStyle(StudioColors.muted)
                    Spacer(minLength: 4)
                    if !editing && page.state == .open {
                        SidebarIconButton(icon: .pencil, label: "Edit Description") {
                            draft = page.body
                            editing = true
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Rectangle().fill(StudioColors.line2).frame(height: 1)
                Group {
                    if editing {
                        VStack(alignment: .leading, spacing: 10) {
                            LiveMarkdownEditor(placeholder: "Describe the pull request — Markdown", text: $draft,
                                               minHeight: 160) { PullRequestLinkRouter.open($0, from: controller) }
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(StudioColors.line3, lineWidth: 1))
                            if let error = entry.errors["body"] { InlineError(message: error) }
                            HStack(spacing: 8) {
                                Spacer(minLength: 0)
                                StudioButton(title: "Cancel", style: .quiet) { editing = false }
                                StudioButton(title: "Save", hint: "⌘⏎", style: .primary,
                                             busy: entry.busy.contains("body")) {
                                    PullRequestStore.shared.perform(.editBody(draft), key: controller.key,
                                                                    root: controller.root) { editing = false }
                                }
                                .keyboardShortcut(.return, modifiers: .command)
                            }
                        }
                    } else if page.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("No description.").font(.studio(13)).foregroundStyle(StudioColors.muted)
                    } else {
                        StudioMarkdownView(markdown: page.body) { PullRequestLinkRouter.open($0, from: controller) }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 16)
            }
        }
    }
}

/// The activity (board 1): pushes, reviews with every comment they carried (`PullRequestPage.reviewComments`),
/// approvals and comments.
struct ActivityList: View {
    @ObservedObject var controller: PullRequestWindowController
    let page: PullRequestPage.Page
    let entry: PullRequestStore.Entry

    var body: some View {
        let comments = PullRequestPage.reviewComments(page.reviews, threads: entry.extras?.threads ?? [])
        VStack(alignment: .leading, spacing: 14) {
            Caption("Activity").padding(.top, 4)
            ForEach(Array(PullRequestPage.activity(page).enumerated()), id: \.offset) { _, item in
                switch item {
                case .pushed(let author, let commits):
                    PushRow(author: author, commits: commits)
                case .reviewed(let review):
                    ReviewEntry(controller: controller, review: review, page: page, entry: entry,
                                comments: comments[review.id] ?? PullRequestPage.ReviewComments())
                case .commented(let comment):
                    CommentEntry(controller: controller, comment: comment)
                }
            }
        }
    }
}

/// "gobinda168 pushed 6 commits": the first two, and "+ 4 more" to see the rest.
private struct PushRow: View {
    let author: String
    let commits: [PullRequestPage.Commit]
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StudioIcon(.commit, size: 16)
                .foregroundStyle(StudioColors.muted)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 6) {
                Text(author).font(.studio(12.5, .semibold)).foregroundStyle(StudioColors.ink)
                    + Text(" pushed \(commits.count) \(commits.count == 1 ? "commit" : "commits")")
                    .font(.studio(12.5)).foregroundStyle(StudioColors.body)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array((expanded ? commits : Array(commits.prefix(2))).enumerated()), id: \.offset) { _, commit in
                        HStack(spacing: 10) {
                            Text(commit.shortOid).font(.studioMono(11.5)).foregroundStyle(StudioColors.coralInk)
                            Text(commit.headline)
                                .font(.studio(12))
                                .foregroundStyle(StudioColors.body)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    if commits.count > 2 && !expanded {
                        Button("+ \(commits.count - 2) more") { expanded = true }
                            .buttonStyle(.plain)
                            .font(.studio(12))
                            .foregroundStyle(StudioColors.coralInk)
                    }
                }
            }
        }
        .padding(.leading, 4)
    }
}

/// A review: one line for a bare approval or request for changes; else a card with the reviewer's words, then every
/// thread it started, whole as the Files page draws it (replies, the reply field, Resolve; resolved ones folded), and
/// its replies to threads started earlier.
private struct ReviewEntry: View {
    @ObservedObject var controller: PullRequestWindowController
    let review: PullRequestPage.Review
    let page: PullRequestPage.Page
    let entry: PullRequestStore.Entry
    let comments: PullRequestPage.ReviewComments

    var body: some View {
        let open = comments.threads.filter { !$0.isResolved }
        let blocking = open.filter { ReviewThreads.severity($0) == .blocking }.count
        let optional = open.filter { ReviewThreads.severity($0) == .optional }.count
        if review.body.isEmpty && comments.isEmpty {
            HStack(spacing: 12) {
                Avatar(login: review.author, size: 24)
                Text(review.author).font(.studio(12.5, .semibold)).foregroundStyle(StudioColors.ink)
                    + Text(" ") + verb
                    + Text(" · \(StudioTime.ago(review.submittedAt))").font(.studio(12.5)).foregroundStyle(StudioColors.body)
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                Avatar(login: review.author, size: 24).padding(.top, 4)
                StudioCard {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 8) {
                            Text(review.author).font(.studio(12.5, .semibold)).foregroundStyle(StudioColors.ink)
                            Text("\(action) · \(StudioTime.ago(review.submittedAt))")
                                .font(.studio(12.5))
                                .foregroundStyle(StudioColors.muted)
                            Spacer(minLength: 4)
                            if blocking > 0 { StatePill(text: "\(blocking) blocking", tone: .danger, height: 20) }
                            if optional > 0 { StatePill(text: "\(optional) optional", tone: .neutral, height: 20) }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        Rectangle().fill(StudioColors.line2).frame(height: 1)
                        VStack(alignment: .leading, spacing: 12) {
                            if !review.body.isEmpty {
                                StudioMarkdownView(markdown: review.body, size: 12.5) {
                                    PullRequestLinkRouter.open($0, from: controller)
                                }
                            }
                            ForEach(comments.threads, id: \.id) { thread in
                                VStack(alignment: .leading, spacing: 6) {
                                    ThreadPlace(controller: controller, thread: thread)
                                    ThreadView(controller: controller, thread: thread, entry: entry, file: nil, page: page)
                                }
                            }
                            ForEach(comments.replies, id: \.comment.id) { reply in
                                ReplyEntry(controller: controller, reply: reply, entry: entry, page: page)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                }
            }
        }
    }

    private var action: String {
        switch review.state {
        case .approved: "approved"
        case .changesRequested: "requested changes"
        case .commented where review.body.isEmpty && comments.threads.isEmpty: "replied"
        default: "reviewed"
        }
    }

    private var verb: Text {
        switch review.state {
        case .approved:
            Text("approved").font(.studio(12.5, .semibold)).foregroundStyle(StudioColors.ok)
                + Text(" these changes").font(.studio(12.5)).foregroundStyle(StudioColors.body)
        case .changesRequested:
            Text("requested changes").font(.studio(12.5, .semibold)).foregroundStyle(StudioColors.danger)
        default:
            Text("commented").font(.studio(12.5)).foregroundStyle(StudioColors.body)
        }
    }
}

/// Where a thread is, over it: the file and line. A click shows it in the Files.
private struct ThreadPlace: View {
    @ObservedObject var controller: PullRequestWindowController
    let thread: ReviewThreads.Thread
    @State private var hovering = false

    var body: some View {
        Button {
            controller.reviewChanges(path: thread.path,
                                     focus: thread.line.map { ReviewThreads.Anchor(side: thread.side, line: $0) })
        } label: {
            HStack(spacing: 6) {
                StudioIcon(.file, size: 13)
                Text(thread.path)
                    .font(.studioMono(11.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                let place = ThreadText.place(thread)
                if !place.isEmpty, !thread.isFileLevel {
                    Text(place).font(.studio(11.5))
                }
            }
            .foregroundStyle(hovering ? StudioColors.ink : StudioColors.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Show It in the Files")
    }
}

/// A reply to a thread an earlier review started: where, the line it answers, the reply, then a field to answer it.
private struct ReplyEntry: View {
    @ObservedObject var controller: PullRequestWindowController
    let reply: PullRequestPage.Reply
    let entry: PullRequestStore.Entry
    let page: PullRequestPage.Page

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ThreadPlace(controller: controller, thread: reply.thread)
            VStack(alignment: .leading, spacing: 8) {
                if let first = reply.thread.comments.first {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        StudioIcon(.reply, size: 12)
                        Text("\(first.author): \(firstLine(first.body))")
                            .font(.studio(12))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .foregroundStyle(StudioColors.muted)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) { Rectangle().fill(StudioColors.line3).frame(width: 2) }
                }
                CommentText(text: reply.comment.body, size: 12.5) { PullRequestLinkRouter.open($0, from: controller) }
                if reply.thread.viewerCanReply {
                    ThreadReplyBox(controller: controller, thread: reply.thread, entry: entry, page: page)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 720, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StudioColors.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(StudioColors.line3, lineWidth: 1))
        }
    }

    private func firstLine(_ body: String) -> String {
        body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }
}

/// A comment on the pull request: its author, age and words.
private struct CommentEntry: View {
    @ObservedObject var controller: PullRequestWindowController
    let comment: PullRequestPage.Comment

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(login: comment.author, size: 24).padding(.top, 4)
            StudioCard {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text(comment.author).font(.studio(12.5, .semibold)).foregroundStyle(StudioColors.ink)
                        Text("commented · \(StudioTime.ago(comment.createdAt))")
                            .font(.studio(12.5))
                            .foregroundStyle(StudioColors.muted)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    Rectangle().fill(StudioColors.line2).frame(height: 1)
                    StudioMarkdownView(markdown: comment.body, size: 13) { PullRequestLinkRouter.open($0, from: controller) }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
            }
        }
    }
}
