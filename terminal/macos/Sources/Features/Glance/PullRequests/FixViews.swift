import GlanceCore
import SwiftUI

/// A thread's fix in its header (board 4): "Claude is fixing" in teal while Claude works, "Fix ready" in green.
struct FixPill: View {
    let job: FixJobs.Job

    var body: some View {
        switch job.state {
        case .preparing, .fixing:
            HStack(spacing: 6) {
                TealDot(size: 8)
                Text(job.isSuggestion ? "Applying" : "Claude is fixing")
            }
            .font(.studio(11.5, .semibold))
            .foregroundStyle(StudioColors.tealInk)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(StudioColors.tealFill))
        case .ready:
            HStack(spacing: 5) {
                StudioIcon(.check, size: 12, weight: 2.4)
                Text("Fix ready")
            }
            .font(.studio(11.5, .semibold))
            .foregroundStyle(StudioColors.ok)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(StudioColors.okFill))
        case .noChanges, .committing, .rejecting, .pushFailed, .done, .rejected, .failed:
            EmptyView()
        }
    }
}

/// What a thread's fix shows in place of its actions (boards 2 and 4):
/// - the teal strip with what Claude is doing and Stop;
/// - Fix ready;
/// - committing;
/// - a failed push with Retry push;
/// - done;
/// - no changes;
/// - rejected;
/// - a failure with Retry.
struct FixPanel: View {
    let job: FixJobs.Job
    /// Fix with Claude again; nil for an applied suggestion.
    let retry: (() -> Void)?

    var body: some View {
        if case .ready(let fix) = job.state {
            // Board 4 sets Claude's fix straight under the comment, with no rule above it.
            FixReady(job: job, fix: fix)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(StudioColors.line2).frame(height: 1)
                state
            }
        }
    }

    @ViewBuilder private var state: some View {
        switch job.state {
        case .preparing:
            strip(job.isSuggestion ? "Applying the suggestion…" : "Getting ready…", stop: false)
        case .fixing(let activity):
            strip(activity ?? "Claude is working", stop: true)
        case .ready:
            EmptyView()
        case .committing:
            strip("Committing and pushing…", stop: false)
        case .rejecting:
            strip("Putting the files back…", stop: false)
        case .pushFailed(let sha, let message):
            note {
                InlineError(message: "Committed \(sha); the push failed: \(message)")
                HStack(spacing: 8) {
                    StudioButton(title: "Retry push", icon: .refresh) { FixJobs.shared.retryPush(root: job.root) }
                    StudioButton(title: "Dismiss", style: .quiet) { FixJobs.shared.dismiss(root: job.root) }
                }
            }
        case .done(let sha, let detail):
            note {
                HStack(spacing: 8) {
                    StudioIcon(.check, size: 14, weight: 2.2).foregroundStyle(StudioColors.ok)
                    Text("Fixed in \(sha).").font(.studio(12.5, .semibold)).foregroundStyle(StudioColors.ink)
                    Spacer(minLength: 8)
                    StudioButton(title: "Dismiss", style: .quiet) { FixJobs.shared.dismiss(root: job.root) }
                }
                if let detail { Text(detail).font(.studio(12)).foregroundStyle(StudioColors.muted) }
            }
        case .noChanges:
            note {
                HStack(spacing: 8) {
                    Text(job.isSuggestion ? "The suggestion changed nothing." : "Claude made no changes.")
                        .font(.studio(12.5))
                        .foregroundStyle(StudioColors.body)
                    Spacer(minLength: 8)
                    StudioButton(title: "Dismiss", style: .quiet) { FixJobs.shared.dismiss(root: job.root) }
                }
            }
        case .rejected(let kept):
            note {
                HStack(spacing: 8) {
                    Text("Put back the fix. Kept \(kept.joined(separator: ", ")): changed again after the fix was ready.")
                        .font(.studio(12.5))
                        .foregroundStyle(StudioColors.body)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    StudioButton(title: "Dismiss", style: .quiet) { FixJobs.shared.dismiss(root: job.root) }
                }
            }
        case .failed(let message):
            note {
                InlineError(message: message, retry: retry)
                StudioButton(title: "Dismiss", style: .quiet) { FixJobs.shared.dismiss(root: job.root) }
            }
        }
    }

    /// The canvas's teal strip: the spinner, what's happening, and Stop (Esc) while Claude works.
    private func strip(_ text: String, stop: Bool) -> some View {
        HStack(spacing: 10) {
            Spinner(size: 15)
            Text(text)
                .font(.studio(12.5, .semibold))
                .foregroundStyle(StudioColors.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if stop {
                StudioButton(title: "Stop", hint: "Esc", style: .quiet, height: 26) {
                    FixJobs.shared.stop(root: job.root)
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioColors.tealFill)
    }

    private func note<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Fix ready (board 4):
/// - exactly what the fix changed;
/// - when it also takes the user's own edits, Accept asks first;
/// - Reply and resolve after push;
/// - Reject (Esc) and Accept fix (⌘↩).
private struct FixReady: View {
    let job: FixJobs.Job
    let fix: FixPatch.Fix
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FixPatchView(title: job.isSuggestion ? "The suggestion" : "Claude's fix", fix: fix)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            if confirming {
                Text("\(fix.overlap.joined(separator: ", ")) also \(fix.overlap.count == 1 ? "has" : "have") your own "
                     + "uncommitted edits: accepting commits those too.")
                    .font(.studio(12))
                    .foregroundStyle(StudioColors.amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
            if let error = job.error {
                InlineError(message: error)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
            Rectangle().fill(StudioColors.line2).frame(height: 1)
            HStack(spacing: 8) {
                Button { FixJobs.shared.setReplyAndResolve(!job.replyAndResolve, root: job.root) } label: {
                    HStack(spacing: 8) {
                        ViewedBox(checked: job.replyAndResolve)
                        Text("Reply and resolve after push").font(.studio(12)).foregroundStyle(StudioColors.body)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(job.replyAndResolve ? [.isSelected] : [])
                Spacer(minLength: 8)
                StudioButton(title: confirming ? "Cancel" : "Reject", hint: "Esc") {
                    if confirming { confirming = false } else { FixJobs.shared.reject(root: job.root) }
                }
                .keyboardShortcut(.escape, modifiers: [])
                StudioButton(title: confirming ? "Commit them too" : "Accept fix", hint: "⌘↩", style: .primary) {
                    if !fix.overlap.isEmpty && !confirming {
                        confirming = true
                    } else {
                        FixJobs.shared.accept(root: job.root)
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

/// A fix's changed lines (board 4's "Claude's fix"): its title and +N −N, then each file's removed and added lines
/// with their numbers. It shows at most 120 lines.
struct FixPatchView: View {
    let title: String
    let fix: FixPatch.Fix

    enum Row {
        case file(String)
        case gap
        case line(PullRequestDiff.Line)
    }

    var body: some View {
        let rows = Self.rows(fix.patch)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.studio(11, .semibold)).foregroundStyle(StudioColors.muted)
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Text("+\(fix.patch.reduce(0) { $0 + $1.additions })").foregroundStyle(StudioColors.ok)
                    Text("−\(fix.patch.reduce(0) { $0 + $1.deletions })").foregroundStyle(StudioColors.danger)
                }
                .font(.studioMono(11, .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(StudioColors.field)
            ForEach(Array(rows.prefix(120).enumerated()), id: \.offset) { _, row in
                rowView(row)
            }
            if rows.count > 120 {
                Text("\(rows.count - 120) more lines")
                    .font(.studio(11))
                    .foregroundStyle(StudioColors.muted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(StudioColors.line, lineWidth: 1))
    }

    /// The changed lines only, as the canvas draws them; each file named when there are several, or when it has no
    /// lines to show (binary, a mode change).
    static func rows(_ files: [PullRequestDiff.File]) -> [Row] {
        var rows: [Row] = []
        for file in files {
            if files.count > 1 || file.hunks.isEmpty {
                rows.append(.file(file.path + (file.isBinary ? " · binary" : file.change == .deleted ? " · deleted" : "")))
            }
            for (index, hunk) in file.hunks.enumerated() {
                if index > 0 { rows.append(.gap) }
                rows += hunk.lines.filter { $0.kind != .context }.map { Row.line($0) }
            }
        }
        return rows
    }

    @ViewBuilder private func rowView(_ row: Row) -> some View {
        switch row {
        case .file(let path):
            Text(path)
                .font(.studioMono(11, .medium))
                .foregroundStyle(StudioColors.body)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .gap:
            Text("⋯")
                .font(.studioMono(11))
                .foregroundStyle(StudioColors.muted)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .line(let line):
            HStack(alignment: .top, spacing: 0) {
                Text((line.new ?? line.old).map(String.init) ?? "")
                    .foregroundStyle(StudioColors.muted)
                    .frame(width: 40, alignment: .trailing)
                    .padding(.trailing, 8)
                Text(line.kind == .added ? "+" : "−")
                    .foregroundStyle(line.kind == .added ? StudioColors.ok : StudioColors.danger)
                    .frame(width: 16, alignment: .leading)
                Text(line.text.isEmpty ? " " : line.text)
                    .foregroundStyle(StudioColors.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.studioMono(11.5))
            .padding(.vertical, 1)
            .background(line.kind == .added ? StudioColors.okFill : StudioColors.dangerFill)
        }
    }
}

/// A thread's Claude actions while no fix runs (board 2):
/// - Fix with Claude in the glow ring on the file's first open thread (⌘I), or with the dot on the others;
/// - Apply suggestion, when the comment has one.
///
/// On another branch, it offers to check out the pull request first.
struct FixActions: View {
    @ObservedObject var controller: PullRequestWindowController
    let thread: ReviewThreads.Thread
    let page: PullRequestPage.Page
    let entry: PullRequestStore.Entry
    let glow: Bool
    /// The thread's lines in the diff: what a suggestion replaces.
    let original: [String]
    @ObservedObject private var fixes = FixJobs.shared

    var body: some View {
        let root = controller.root
        let checkedOut = root.map { GitHead.branch(inFolder: $0) == page.head } ?? false
        let busy = root.map { fixes.isBusy(root: $0) } ?? false
        let claude = entry.read != .unavailable
        let suggestion = ReviewThreads.suggestion(in: thread.comments.first?.body ?? "")
        HStack(spacing: 8) {
            if root == nil {
                // Not on this Mac: the actions show, dimmed, with why.
                Group {
                    if glow {
                        GlowPill(title: "Fix with Claude", hint: "⌘I", enabled: false) {}
                    } else {
                        DotButton(title: "Fix with Claude", enabled: false) {}
                    }
                    if suggestion != nil, thread.side == .right, !original.isEmpty {
                        StudioButton(title: "Apply suggestion", enabled: false) {}
                    }
                }
                .help(LocalFolderNotice.needs(controller.key.repository))
            } else if !checkedOut {
                StudioButton(title: "Check out #\(page.number)", icon: .download,
                             busy: entry.busy.contains("checkout")) {
                    PullRequestStore.shared.perform(.checkout, key: controller.key, root: controller.root)
                }
                .help("Fixes happen in your project, on the pull request's branch")
            } else {
                if glow {
                    GlowPill(title: "Fix with Claude", hint: "⌘I", enabled: claude && !busy) { fix() }
                        .keyboardShortcut("i", modifiers: .command)
                        .help(tooltip(claude: claude, busy: busy))
                } else {
                    DotButton(title: "Fix with Claude", enabled: claude && !busy) { fix() }
                        .help(tooltip(claude: claude, busy: busy))
                }
                if let suggestion, thread.side == .right, !original.isEmpty {
                    StudioButton(title: "Apply suggestion", enabled: !busy) {
                        guard let root = controller.root else { return }
                        FixJobs.shared.applySuggestion(thread, lines: suggestion.lines, original: original,
                                                       key: controller.key, root: root)
                    }
                    .help("Writes the suggested lines in your working tree; you accept or reject them")
                }
            }
        }
    }

    private func fix() {
        guard let root = controller.root else { return }
        FixJobs.shared.fix([thread], page: page, key: controller.key, root: root, window: controller.window)
    }

    private func tooltip(claude: Bool, busy: Bool) -> String {
        if !claude { return "Install Claude Code to fix with Claude" }
        if busy { return "A fix is under way in this project" }
        return "Claude changes your working tree; you accept or reject" + (glow ? " (⌘I)" : "")
    }
}

/// A Claude action without the glow (MASTER §7.1, one ring per page): the coral dot and its words, as a secondary
/// button.
struct DotButton: View {
    let title: String
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                CoralDot(size: 9)
                Text(title).font(.studio(12, .medium)).foregroundStyle(StudioColors.ink)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? StudioColors.hover : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(StudioColors.line3, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
    }
}

/// The canvas's spinner (`.spin`): a teal arc turning once every 0.9 s; still under Reduce Motion.
struct Spinner: View {
    var size: CGFloat = 15
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false

    var body: some View {
        StudioIcon(.spinner, size: size)
            .foregroundStyle(StudioColors.tealInk)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(reduceMotion ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false), value: turning)
            .onAppear { turning = true }
            .accessibilityHidden(true)
    }
}
