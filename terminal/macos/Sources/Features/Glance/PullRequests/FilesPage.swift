import AppKit
import GlanceCore
import SwiftUI

/// The Files page, the review (board 2): one file at a time, chosen in the side bar or with the previous and next
/// buttons. It holds:
/// - the toolbar;
/// - the diff, unified or split, with its threads;
/// - the comment being written;
/// - Finish review.
///
/// A commit's changes show read-only, under a chip back to all of them.
struct FilesPage: View {
    @ObservedObject var controller: PullRequestWindowController
    let page: PullRequestPage.Page
    let entry: PullRequestStore.Entry
    @ObservedObject private var store = PullRequestStore.shared
    @ObservedObject private var tabSidebar = TabSidebarModel.shared
    @ObservedObject private var modes = SidebarModeModel.shared
    @AppStorage("reviewDiffLayout") private var layout: DiffLayout = .unified
    @State private var composing: Composing?
    @State private var draft = ""
    @State private var picking: Composing?
    @State private var finishing = false
    @State private var shownLarge: Set<String> = []
    @State private var frames = DiffLineFrames()
    @State private var hover = HoverBox()
    @State private var keys = CommentKeyMonitor()
    @State private var mode: ComposeMode = .comment
    @ObservedObject private var asks = DiffAsks.shared
    @ObservedObject private var inbox = ReviewInboxStore.shared

    /// A comment on `end`'s line, from `start`'s for a range: the one being written, or the range being dragged (from
    /// where the drag started).
    struct Composing: Equatable {
        var start: ReviewThreads.Anchor?
        var end: ReviewThreads.Anchor
    }

    var body: some View {
        VStack(spacing: 0) {
            switch diff {
            case .ready(let files)?:
                if let file = files.first(where: { $0.path == controller.file }) ?? files.first {
                    FilesToolbar(controller: controller, entry: entry, file: file, files: files, layout: $layout,
                                 finishing: $finishing, showsBack: !(tabSidebar.isOpen && modes.mode == .pullRequests),
                                 canAsk: canAsk, askFile: { askShortcut(file) })
                    diffList(file)
                } else {
                    Text("No changes.")
                        .font(.studio(13))
                        .foregroundStyle(StudioColors.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .failed(let message)?:
                InlineError(message: "Couldn't read the changes: \(message)") { load() }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .loading?, nil:
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading the changes…").font(.studio(12)).foregroundStyle(StudioColors.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .topTrailing) {
            if finishing {
                FinishReviewCard(controller: controller, page: page, entry: entry) { finishing = false }
                    .padding(.top, 52)
                    .padding(.trailing, 16)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .animation(.easeOut(duration: 0.16), value: finishing)
        .task(id: controller.commit ?? page.headOid) { load() }
        .onChange(of: controller.file) { _, _ in
            composing = nil
            picking = nil
            mode = .comment
        }
        .onAppear {
            inbox.checkClaude()
            keys.start(window: controller.window, line: { hover.anchor },
                       comment: { anchor in compose(anchor, ask: controller.commit != nil) },
                       ask: { anchor in compose(anchor, ask: true) })
        }
        .onDisappear { keys.stop() }
    }

    private var diff: PullRequestStore.DiffState? {
        if let sha = controller.commit { return store.diffs[PullRequestStore.commitKey(controller.key, sha: sha)] }
        return store.diffs[PullRequestStore.diffKey(controller.key, head: page.headOid)]
    }

    private var readOnly: Bool { controller.commit != nil }
    private var canAsk: Bool { inbox.claudeInstalled != false }
    private var ownerKey: String { DiffAsks.key(controller.key) }

    /// A commit's lines aren't the PR's: its boxes are kept apart.
    private func boxPath(_ file: PullRequestDiff.File) -> String {
        controller.commit.map { "\($0):\(file.path)" } ?? file.path
    }

    private var owner: DiffAsks.Owner {
        DiffAsks.Owner(key: ownerKey, folder: controller.root,
                       subject: .pullRequest(number: page.number, title: page.title,
                                             repository: controller.key.repository, head: page.head, base: page.base))
    }

    /// Opens the line box: on Ask for A and read-only diffs, else on Comment.
    private func compose(_ anchor: ReviewThreads.Anchor, ask: Bool) {
        if (ask || readOnly) && !canAsk { NSSound.beep(); return }
        composing = Composing(start: nil, end: anchor)
        mode = ask || readOnly ? .ask : .comment
    }

    /// ⌘I: the line box switches to Ask; with none open, a box about the file.
    private func askShortcut(_ file: PullRequestDiff.File) {
        guard canAsk else { NSSound.beep(); return }
        if composing != nil { mode = .ask; return }
        asks.open(owner, file: file, path: boxPath(file), scope: .file, question: nil)
    }

    private func askLines(_ composing: Composing, file: PullRequestDiff.File) {
        asks.open(owner, file: file, path: boxPath(file), scope: .lines(start: composing.start, end: composing.end),
                  question: draft)
        self.composing = nil
        draft = ""
    }

    private func load() {
        if let sha = controller.commit {
            store.loadCommitDiff(controller.key, sha: sha)
        } else {
            store.loadDiff(controller.key, head: page.headOid)
        }
    }

    private func diffList(_ file: PullRequestDiff.File) -> some View {
        let readOnly = controller.commit != nil
        let placement = readOnly ? ReviewThreads.Placement()
            : ReviewThreads.placement(entry.extras?.threads ?? [], path: file.path, file: file)
        let boxes = asks.boxes(ownerKey, path: boxPath(file))
        let lineBoxes = Dictionary(grouping: boxes.filter { $0.anchor != nil }, by: { $0.anchor! })
            .mapValues { $0.map(\.id) }
        let items = DiffItem.items(file, layout: layout, placement: placement, composing: composing?.end,
                                   asks: lineBoxes)
        let selected = range(picking ?? composing)
        // MASTER §7.1, one glow ring per page: the Fix with Claude of the file's first open thread.
        let inline = items.flatMap { item -> [ReviewThreads.Thread] in
            if case .threads(let threads, _) = item { return threads }
            return []
        }
        let glowThreadID = (placement.fileLevel + inline).first { !$0.isResolved && !$0.isPending }?.id
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    if let sha = controller.commit {
                        CommitChip(sha: sha, commit: page.commits.first(where: { $0.oid == sha })) {
                            controller.commit = nil
                            controller.file = nil
                        }
                    }
                    if !placement.fileLevel.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Caption("On this file")
                            ForEach(placement.fileLevel, id: \.id) { thread in
                                ThreadView(controller: controller, thread: thread, entry: entry, file: file, page: page,
                                           glow: thread.id == glowThreadID)
                            }
                        }
                    }
                    if !placement.outdated.isEmpty {
                        OutdatedThreads(controller: controller, threads: placement.outdated, entry: entry, page: page)
                    }
                    ForEach(boxes.filter { $0.anchor == nil }) { box in
                        DiffAskBox(box: box, owner: ownerKey) { PullRequestLinkRouter.open($0, from: controller) }
                    }
                    card(file, items: items, selected: selected, readOnly: readOnly, glowThreadID: glowThreadID,
                         boxes: boxes)
                    if readOnly { askHint } else { hint }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
            .id(file.path + (controller.commit ?? ""))
            .task(id: controller.focus) {
                guard let focus = controller.focus else { return }
                try? await Task.sleep(for: .milliseconds(150))
                if let item = items.first(where: { $0.anchors.contains(focus) }) {
                    withAnimation(.easeOut(duration: 0.24)) { proxy.scrollTo(item.id, anchor: .center) }
                }
                controller.focus = nil
            }
        }
    }

    @ViewBuilder private func card(_ file: PullRequestDiff.File, items: [DiffItem], selected: Set<ReviewThreads.Anchor>,
                                   readOnly: Bool, glowThreadID: String?, boxes: [DiffAsks.Box]) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Group {
            if let notice = Self.notice(file) {
                Text(notice)
                    .font(.studio(12.5))
                    .foregroundStyle(StudioColors.muted)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if file.isLarge && !shownLarge.contains(file.path) {
                HStack(spacing: 12) {
                    Text("\(file.additions + file.deletions) changed lines, folded to keep the page quick.")
                        .font(.studio(12.5))
                        .foregroundStyle(StudioColors.body)
                    StudioButton(title: "Show the diff") { shownLarge.insert(file.path) }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                let interaction = LineInteraction(
                    hover: hover,
                    comment: { compose($0, ask: readOnly) },
                    drag: { pick(from: $0, to: $1) },
                    dragEnded: { endPick() },
                    canComment: !readOnly)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        row(item, file: file, interaction: interaction, selected: selected, glowThreadID: glowThreadID,
                            boxes: boxes)
                    }
                }
                .coordinateSpace(.named(DiffSpace.name))
                .onPreferenceChange(DiffLineFrameKey.self) { frames.frames = $0 }
            }
        }
        .background(shape.fill(StudioColors.card))
        .clipShape(shape)
        .overlay(shape.strokeBorder(StudioColors.line, lineWidth: 1))
    }

    @ViewBuilder private func row(_ item: DiffItem, file: PullRequestDiff.File, interaction: LineInteraction?,
                                  selected: Set<ReviewThreads.Anchor>, glowThreadID: String?,
                                  boxes: [DiffAsks.Box]) -> some View {
        switch item {
        case .hunk(_, let header):
            Text(header)
                .font(.studioMono(11.5))
                .foregroundStyle(StudioColors.muted)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .background(StudioColors.field)
                .overlay(alignment: .bottom) { Rectangle().fill(StudioColors.line2).frame(height: 1) }
        case .unified(let line, _):
            UnifiedLineView(line: line, twoColumns: file.change == .modified || file.change == .renamed,
                            language: SyntaxHighlight.Language(path: file.path),
                            interaction: interaction,
                            selected: DiffItem.commentAnchor(line).map { selected.contains($0) } ?? false)
        case .split(let pair, _, _):
            SplitLineView(row: pair, language: SyntaxHighlight.Language(path: file.path), interaction: interaction,
                          selected: selected)
        case .threads(let threads, _):
            InlineThreads(controller: controller, threads: threads, entry: entry, file: file, page: page,
                          glowThreadID: glowThreadID)
        case .ask(let id):
            if let box = boxes.first(where: { $0.id == id }) {
                DiffAskBox(box: box, owner: ownerKey) { PullRequestLinkRouter.open($0, from: controller) }
                    .inlineBlock()
            }
        case .composer:
            if let composing {
                CommentComposer(title: mode == .ask || readOnly
                                    ? "Ask Claude about " + DiffAsk.place(.lines(start: composing.start, end: composing.end))
                                    : ThreadText.composing(start: composing.start, end: composing.end),
                                text: $draft,
                                busy: entry.busy.contains(PullRequestStore.ReviewAction.commentName),
                                error: entry.errors[PullRequestStore.ReviewAction.commentName],
                                cancel: { self.composing = nil },
                                add: { add(composing, file: file) },
                                mode: readOnly ? nil : $mode, asksOnly: readOnly, canAsk: canAsk,
                                ask: { askLines(composing, file: file) })
                    .inlineBlock()
            }
        }
    }

    private var hint: some View {
        HStack(spacing: 6) {
            StudioIcon(.plus, size: 14)
            Text("Hover a line number and press")
            Kbd("+")
            Text("or")
            Kbd("C")
            Text("to comment,")
            Kbd("A")
            Text("to ask Claude; drag across numbers for a range.")
        }
        .font(.studio(12))
        .foregroundStyle(StudioColors.muted)
    }

    private var askHint: some View {
        HStack(spacing: 6) {
            Text("Hover a line number and press")
            Kbd("A")
            Text("to ask Claude about it; drag across numbers for a range.")
        }
        .font(.studio(12))
        .foregroundStyle(StudioColors.muted)
    }

    private func add(_ composing: Composing, file: PullRequestDiff.File) {
        let action = PullRequestStore.ReviewAction.comment(
            path: file.path, line: composing.end.line, side: composing.end.side, startLine: composing.start?.line,
            startSide: composing.start?.side, body: draft)
        store.review(action, key: controller.key) {
            self.composing = nil
            draft = ""
        }
    }

    /// A drag across numbers: the line where it started to the one under the pointer (on the same side in the split
    /// view).
    private func pick(from start: CGPoint, to point: CGPoint) {
        if let picked = DiffPicking.picked(from: start, to: point, frames: frames.frames, split: layout == .split) {
            picking = picked
        }
    }

    /// The range dragged becomes the box being written, its top line first: Ask on a read-only diff.
    private func endPick() {
        defer { picking = nil }
        guard let ordered = DiffPicking.ordered(picking, frames: frames.frames) else { return }
        if readOnly && !canAsk { NSSound.beep(); return }
        composing = ordered
        mode = readOnly ? .ask : .comment
    }

    /// The lines between a range's ends, by where their numbers are (on the same side in the split view).
    private func range(_ range: Composing?) -> Set<ReviewThreads.Anchor> {
        DiffPicking.range(range, frames: frames.frames, split: layout == .split)
    }

    /// What shows instead of lines: a binary file, a rename or mode change with no lines changed, an empty file.
    static func notice(_ file: PullRequestDiff.File) -> String? {
        guard file.hunks.isEmpty else { return nil }
        if file.isBinary { return "Binary file not shown." }
        if file.change == .renamed, let old = file.oldPath { return "Renamed from \(old) without changes." }
        if let old = file.oldMode, let new = file.newMode { return "File mode changed from \(old) to \(new)." }
        return "No lines to show."
    }
}

/// The Files page's toolbar (board 2):
/// - the path;
/// - what happened to the file, and its +/−;
/// - Unified / Split;
/// - Viewed;
/// - previous and next;
/// - the pending count and Finish review.
private struct FilesToolbar: View {
    @ObservedObject var controller: PullRequestWindowController
    let entry: PullRequestStore.Entry
    let file: PullRequestDiff.File
    let files: [PullRequestDiff.File]
    @Binding var layout: DiffLayout
    @Binding var finishing: Bool
    /// The changed files aren't in the side bar: a way back to the Overview.
    let showsBack: Bool
    let canAsk: Bool
    /// ⌘I: Ask Claude about this file, or switch the open line box to Ask.
    let askFile: () -> Void

    var body: some View {
        let index = files.firstIndex { $0.path == file.path } ?? 0
        let readOnly = controller.commit != nil
        let viewed = entry.extras?.viewed.contains(file.path) ?? false
        let pending = entry.extras?.pendingCount ?? 0
        HStack(spacing: 10) {
            if showsBack {
                SidebarIconButton(icon: .chevronLeft, label: "Overview") { controller.section = .overview }
            }
            FilePath(path: file.path)
            ChangeChip(file: file)
            HStack(spacing: 6) {
                if file.additions > 0 { Text("+\(file.additions)").foregroundStyle(StudioColors.ok) }
                if file.deletions > 0 { Text("−\(file.deletions)").foregroundStyle(StudioColors.danger) }
            }
            .font(.studioMono(11))
            LayoutPicker(layout: $layout)
                .padding(.leading, 6)
            if !readOnly {
                Button {
                    PullRequestStore.shared.review(.viewed(path: file.path, !viewed), key: controller.key)
                } label: {
                    HStack(spacing: 6) {
                        ViewedBox(checked: viewed)
                        Text("Viewed").font(.studio(12)).foregroundStyle(StudioColors.body)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(entry.extras == nil)
                .help(viewed ? "Mark as Not Viewed" : "Mark as Viewed")
                .accessibilityAddTraits(viewed ? .isSelected : [])
            }
            HStack(spacing: 2) {
                SidebarIconButton(icon: .chevronUp, label: "Previous File (⌥⌘↑)") { go(to: index - 1) }
                    .disabled(index == 0)
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                SidebarIconButton(icon: .chevronDown, label: "Next File (⌥⌘↓)") { go(to: index + 1) }
                    .disabled(index >= files.count - 1)
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            }
            Spacer(minLength: 8)
            StudioButton(title: "Ask Claude", enabled: canAsk, height: 26, action: askFile)
                .keyboardShortcut("i", modifiers: .command)
                .help(canAsk ? "Ask Claude about this file (⌘I)" : "Install Claude Code to ask Claude")
            if !readOnly {
                if pending > 0 {
                    HStack(spacing: 6) {
                        StudioIcon(.clock, size: 14)
                        Text("\(pending) pending")
                    }
                    .font(.studio(12, .semibold))
                    .foregroundStyle(StudioColors.amber)
                }
                FinishReviewButton { finishing.toggle() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 46)
        .background(StudioColors.background)
        .overlay(alignment: .bottom) { Rectangle().fill(StudioColors.line).frame(height: 1) }
    }

    private func go(to index: Int) {
        guard files.indices.contains(index) else { return }
        controller.file = files[index].path
    }
}

/// "scripts/" muted, then "release.sh" semibold, in mono.
private struct FilePath: View {
    let path: String

    var body: some View {
        let slash = path.lastIndex(of: "/")
        HStack(spacing: 0) {
            if let slash { Text(path[...slash]).foregroundStyle(StudioColors.muted) }
            Text(slash.map { String(path[path.index(after: $0)...]) } ?? path)
                .fontWeight(.semibold)
                .foregroundStyle(StudioColors.ink)
        }
        .font(.studioMono(12))
        .lineLimit(1)
        .truncationMode(.head)
        .help(path)
    }
}

/// NEW FILE, DELETED, RENAMED or BINARY: the canvas's 20 pt chip.
private struct ChangeChip: View {
    let file: PullRequestDiff.File

    var body: some View {
        if let label {
            Text(label.text)
                .font(.studio(10.5, .semibold))
                .foregroundStyle(label.ink)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(label.fill))
                .help(file.oldPath.map { "Renamed from \($0)" } ?? "")
        }
    }

    private var label: (text: String, ink: Color, fill: Color)? {
        if file.isBinary { return ("BINARY", StudioColors.muted, StudioColors.chip) }
        switch file.change {
        case .added: return ("NEW FILE", StudioColors.ok, StudioColors.okFill)
        case .deleted: return ("DELETED", StudioColors.danger, StudioColors.dangerFill)
        case .renamed: return ("RENAMED", StudioColors.muted, StudioColors.chip)
        case .modified: return nil
        }
    }
}

/// Unified / Split: the canvas's small segmented control.
private struct LayoutPicker: View {
    @Binding var layout: DiffLayout

    var body: some View {
        HStack(spacing: 0) {
            option(.unified, "Unified")
            option(.split, "Split")
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(StudioColors.field))
        .animation(.easeOut(duration: 0.24), value: layout)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Diff Layout")
    }

    private func option(_ value: DiffLayout, _ title: String) -> some View {
        let selected = layout == value
        return Button { layout = value } label: {
            Text(title)
                .font(.studio(11.5, selected ? .semibold : .medium))
                .foregroundStyle(selected ? StudioColors.ink : StudioColors.muted)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(selected ? StudioColors.solid : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The canvas's checkbox: a 13 pt box, coral and ticked when on.
struct ViewedBox: View {
    let checked: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(checked ? StudioColors.coral : .clear)
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(checked ? .clear : StudioColors.line3, lineWidth: 1))
            .overlay {
                if checked { StudioIcon(.check, size: 10, weight: 2.6).foregroundStyle(StudioColors.onCoral) }
            }
            .frame(width: 13, height: 13)
            .accessibilityHidden(true)
    }
}

/// Finish review, the toolbar's coral button with its chevron.
private struct FinishReviewButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text("Finish review").font(.studio(12, .semibold))
                StudioIcon(.chevronDown, size: 14)
            }
            .foregroundStyle(StudioColors.onCoral)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? StudioColors.coralHover : StudioColors.coral))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .help("Finish Your Review")
    }
}

/// Finish your review (board 2):
/// - a summary;
/// - the verdict (Approve and Request changes are off on your own pull request);
/// - how many pending comments it posts;
/// - Cancel, and the verdict's button ⌘↩.
private struct FinishReviewCard: View {
    @ObservedObject var controller: PullRequestWindowController
    let page: PullRequestPage.Page
    let entry: PullRequestStore.Entry
    let close: () -> Void
    @State private var summary = ""
    @State private var verdict: ReviewMutations.Event = .comment

    var body: some View {
        let pending = entry.extras?.pendingCount ?? 0
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Finish your review").font(.studio(14, .bold)).foregroundStyle(StudioColors.ink)
                Spacer(minLength: 8)
                SidebarIconButton(icon: .close, label: "Close", action: close)
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.top, 8)
            .padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 10) {
                StudioTextEditor(placeholder: "Leave a summary (optional)", text: $summary, minHeight: 64)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.background))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(StudioColors.line3, lineWidth: 1))
                VStack(spacing: 6) {
                    option(.comment, "Comment", "General feedback without approving.")
                    option(.approve, "Approve", "Ready to merge once checks pass.")
                    option(.requestChanges, "Request changes", "Blocks merging until your comments are addressed.")
                }
                if let error = entry.errors[PullRequestStore.ReviewAction.submitName] { InlineError(message: error) }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            Rectangle().fill(StudioColors.line2).frame(height: 1)
            HStack(spacing: 8) {
                Text(pending == 0 ? "No pending comments"
                     : "Posts \(pending) pending \(pending == 1 ? "comment" : "comments")")
                    .font(.studio(11.5))
                    .foregroundStyle(StudioColors.muted)
                Spacer(minLength: 8)
                StudioButton(title: "Cancel", style: .quiet, action: close)
                    .keyboardShortcut(.escape, modifiers: [])
                StudioButton(title: title, hint: "⌘↩", style: .primary,
                             busy: entry.busy.contains(PullRequestStore.ReviewAction.submitName),
                             enabled: canSubmit(pending: pending)) { submit() }
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 380)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(StudioColors.card))
        .overlay(alignment: .top) { Rectangle().fill(StudioColors.rim).frame(height: 1).padding(.horizontal, 12) }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(StudioColors.line3, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 12)
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
    }

    private var ownPullRequest: Bool { entry.extras?.viewer == page.author }

    private var title: String {
        switch verdict {
        case .comment: "Comment"
        case .approve: "Approve"
        case .requestChanges: "Request changes"
        }
    }

    /// GitHub wants words or pending comments for Comment and Request changes.
    private func canSubmit(pending: Int) -> Bool {
        if verdict != .comment && ownPullRequest { return false }
        if verdict == .approve { return true }
        return pending > 0 || !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func option(_ value: ReviewMutations.Event, _ title: String, _ detail: String) -> some View {
        let selected = verdict == value
        let off = value != .comment && ownPullRequest
        return Button { verdict = value } label: {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .strokeBorder(selected ? StudioColors.coral : StudioColors.line3, lineWidth: selected ? 4.5 : 1)
                    .frame(width: 15, height: 15)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.studio(12.5, .semibold)).foregroundStyle(StudioColors.ink)
                    Text(off ? "Not on your own pull request." : detail)
                        .font(.studio(11.5))
                        .foregroundStyle(StudioColors.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? StudioColors.selection : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? StudioColors.coral : StudioColors.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(off)
        .opacity(off ? 0.5 : 1)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func submit() {
        PullRequestStore.shared.review(.submit(verdict, body: summary), key: controller.key) {
            summary = ""
            close()
            // The review shows on the Overview, and the review decision may change.
            PullRequestStore.shared.load(controller.key, root: controller.root, force: true)
        }
    }
}

/// The commit whose changes show, and the way back to all of them.
private struct CommitChip: View {
    let sha: String
    let commit: PullRequestPage.Commit?
    let back: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            StudioIcon(.commit, size: 14).foregroundStyle(StudioColors.coralInk)
            Text(String(sha.prefix(7))).font(.studioMono(11.5)).foregroundStyle(StudioColors.coralInk)
            if let commit {
                Text(commit.headline).font(.studio(12.5)).foregroundStyle(StudioColors.ink).lineLimit(1)
            }
            Spacer(minLength: 8)
            StudioButton(title: "All changes", icon: .close, style: .quiet, action: back)
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StudioColors.selection))
    }
}

/// "N outdated threads" at the file's top: folded; a click opens them.
private struct OutdatedThreads: View {
    @ObservedObject var controller: PullRequestWindowController
    let threads: [ReviewThreads.Thread]
    let entry: PullRequestStore.Entry
    let page: PullRequestPage.Page
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    StudioIcon(open ? .chevronDown : .chevronRight, size: 12)
                    Text("\(threads.count) outdated \(threads.count == 1 ? "thread" : "threads")")
                }
                .font(.studio(12, .semibold))
                .foregroundStyle(StudioColors.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? "expanded" : "collapsed")
            if open {
                ForEach(threads, id: \.id) { thread in
                    ThreadView(controller: controller, thread: thread, entry: entry, file: nil, page: page)
                }
            }
        }
    }
}

/// C or + over a line starts a comment there, A a question to Claude, unless a text field has the keys: a local key
/// monitor on the tab's window while a diff shows.
final class CommentKeyMonitor {
    private var monitor: Any?

    func start(window: NSWindow?, line: @escaping () -> ReviewThreads.Anchor?,
               comment: @escaping (ReviewThreads.Anchor) -> Void,
               ask: @escaping (ReviewThreads.Anchor) -> Void = { _ in }) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
            guard let window, event.window === window,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let key = event.charactersIgnoringModifiers?.lowercased(), ["c", "+", "a"].contains(key),
                  !(window.firstResponder is NSText),
                  let anchor = line() else { return event }
            if key == "a" { ask(anchor) } else { comment(anchor) }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { stop() }
}
