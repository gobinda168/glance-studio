import AppKit
import GlanceCore
import SwiftUI

/// The Checks page (spec: "Pages → Checks"; not on the canvas, drawn in its style). It lists the head commit's checks
/// as failing, running, passing and skipped (folded: a branch can skip a hundred jobs), each with its workflow and
/// duration.
/// - A failed Actions job unfolds to the end of its failed step's log, with Re-run failed jobs. The first such job
///   starts unfolded.
/// - Another app's check run unfolds to its title and summary.
/// - A check whose page is off GitHub offers it in the browser.
///
/// Nothing opens github.com.
struct ChecksListPage: View {
    @ObservedObject var controller: PullRequestWindowController
    let page: PullRequestPage.Page
    let entry: PullRequestStore.Entry
    /// Unfolded rows by `rowID`. Nil until the user folds or unfolds one; until then the first failed job is unfolded.
    @State private var unfolded: Set<String>? = nil
    @State private var showsSkipped = false

    var body: some View {
        let checks = entry.shownChecks(page)
        if checks.isEmpty {
            Text("No checks on this branch.").font(.studio(13)).foregroundStyle(StudioColors.muted)
        } else {
            let open = unfolded ?? Set([Self.firstFailedJob(checks)].compactMap { $0 })
            VStack(alignment: .leading, spacing: 20) {
                ForEach(PullRequestChecks.groups(checks), id: \.outcome) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        header(group)
                        if group.outcome != .skipped || showsSkipped {
                            StudioCard {
                                VStack(spacing: 0) {
                                    ForEach(Array(group.checks.enumerated()), id: \.offset) { index, check in
                                        CheckRow(controller: controller, check: check, entry: entry,
                                                 unfolded: binding(Self.rowID(check), open: open))
                                        if index < group.checks.count - 1 {
                                            Rectangle().fill(StudioColors.line2).frame(height: 1)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// "FAILING · 1". Skipped's opens and shuts.
    @ViewBuilder private func header(_ group: PullRequestChecks.Group) -> some View {
        let title = "\(Self.title(group.outcome)) · \(group.checks.count)"
        if group.outcome == .skipped {
            Button { showsSkipped.toggle() } label: {
                HStack(spacing: 6) {
                    StudioIcon(showsSkipped ? .chevronDown : .chevronRight, size: 12)
                        .foregroundStyle(StudioColors.muted)
                    Caption(title)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showsSkipped ? "expanded" : "collapsed")
        } else {
            Caption(title)
        }
    }

    private func binding(_ id: String, open: Set<String>) -> Binding<Bool> {
        Binding(get: { open.contains(id) }, set: { isOpen in
            var rows = open
            if isOpen { rows.insert(id) } else { rows.remove(id) }
            unfolded = rows
        })
    }

    /// A row's identity: its check run when it has one (gh can list two checks with the same name), else its name.
    static func rowID(_ check: PullRequestChecks.Check) -> String {
        switch check.source {
        case .job(_, _, let id), .checkRun(_, let id): "\(id)"
        case .elsewhere, .unknown: check.workflow + "\u{1F}" + check.name
        }
    }

    /// The first failed Actions job, unfolded when the page opens.
    static func firstFailedJob(_ checks: [PullRequestChecks.Check]) -> String? {
        checks.first { check in
            if case .job = check.source { return check.outcome == .failed }
            return false
        }.map(rowID)
    }

    static func title(_ outcome: PullRequestPage.Check.Outcome) -> String {
        switch outcome {
        case .failed: "Failing"
        case .running: "Running"
        case .passed: "Passing"
        case .skipped: "Skipped"
        }
    }
}

/// One check: outcome, name, workflow and duration, folded or unfolded to what it has to show.
private struct CheckRow: View {
    @ObservedObject var controller: PullRequestWindowController
    let check: PullRequestChecks.Check
    let entry: PullRequestStore.Entry
    @Binding var unfolded: Bool
    @ObservedObject private var store = PullRequestStore.shared
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if canUnfold {
                Button { unfolded.toggle() } label: { header }
                    .buttonStyle(.plain)
                    .onHover { hovering = $0 }
                    .animation(.easeOut(duration: 0.16), value: hovering)
                    .accessibilityValue(unfolded ? "expanded" : "collapsed")
                    .accessibilityHint(isJob ? "Shows the end of the failed step's log" : "Shows its summary")
                if unfolded {
                    detail
                        .padding(.leading, 38)
                        .padding(.trailing, 14)
                        .padding(.bottom, 12)
                }
            } else {
                header
            }
        }
        .task(id: unfolded) {
            if unfolded && canUnfold { store.loadDetail(check.source) }
        }
    }

    private var isJob: Bool {
        if case .job = check.source { return true }
        return false
    }

    /// A failed Actions job has a log to show; a finished check run has its title and summary.
    private var canUnfold: Bool {
        switch check.source {
        case .job: check.outcome == .failed
        case .checkRun: check.outcome != .running
        case .elsewhere, .unknown: false
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            CheckOutcomeIcon(outcome: check.outcome)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(check.name)
                        .font(.studioMono(12))
                        .foregroundStyle(StudioColors.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !check.workflow.isEmpty {
                        Text("· \(check.workflow)")
                            .font(.studio(12))
                            .foregroundStyle(StudioColors.muted)
                            .lineLimit(1)
                    }
                }
                if !check.description.isEmpty {
                    Text(check.description)
                        .font(.studio(12))
                        .foregroundStyle(StudioColors.body)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let duration = PullRequestChecks.duration(check, now: Date()) {
                Text(duration).font(.studioMono(11)).foregroundStyle(StudioColors.muted)
            }
            if case .elsewhere(let url) = check.source {
                Button("Details") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.plain)
                    .font(.studio(12))
                    .foregroundStyle(StudioColors.coralInk)
                    .help("Open \(url.host ?? "its page") in the browser")
            }
            if canUnfold {
                StudioIcon(unfolded ? .chevronDown : .chevronRight, size: 12)
                    .foregroundStyle(StudioColors.muted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 34)
        .background(hovering && canUnfold ? StudioColors.hover : .clear)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var detail: some View {
        switch check.source {
        case .job(let repository, let run, let id):
            VStack(alignment: .leading, spacing: 10) {
                switch store.details[id] {
                case .log(let log)?:
                    JobLogView(log: log)
                case .empty?, .output?:
                    Text("GitHub has no log for the failed step.")
                        .font(.studio(12))
                        .foregroundStyle(StudioColors.muted)
                case .failed(let message)?:
                    InlineError(message: "Couldn't read the log: \(message)") { store.loadDetail(check.source) }
                case .loading?, nil:
                    Reading(text: "Reading the log…")
                }
                let action = PullRequestStore.Action.rerun(repository: repository, run: run)
                StudioButton(title: "Re-run failed jobs", icon: .refresh, busy: entry.busy.contains(action.name)) {
                    PullRequestStore.shared.perform(action, key: controller.key, root: controller.root)
                }
                if let error = entry.errors[action.name] { InlineError(message: error) }
            }
        case .checkRun(_, let id):
            switch store.details[id] {
            case .output(let output)?:
                CheckRunSummary(output: output) { PullRequestLinkRouter.open($0, from: controller) }
            case .empty?, .log?:
                Text("No summary.").font(.studio(12)).foregroundStyle(StudioColors.muted)
            case .failed(let message)?:
                InlineError(message: "Couldn't read it: \(message)") { store.loadDetail(check.source) }
            case .loading?, nil:
                Reading(text: "Reading…")
            }
        case .elsewhere, .unknown:
            EmptyView()
        }
    }
}

/// The end of a failed step's log: the step's name, then its last lines in mono (errors in red), selectable as one
/// text.
private struct JobLogView: View {
    let log: PullRequestChecks.Log

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !log.step.isEmpty {
                HStack(spacing: 6) {
                    Caption("Failed step")
                    Text(log.step)
                        .font(.studioMono(11))
                        .foregroundStyle(StudioColors.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                if log.omitted > 0 {
                    Text("\(log.omitted) earlier \(log.omitted == 1 ? "line" : "lines")")
                        .font(.studio(11))
                        .foregroundStyle(StudioColors.muted)
                }
                Text(Self.text(log.lines))
                    .font(.studioMono(11))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.field))
        }
    }

    static func text(_ lines: [PullRequestChecks.Line]) -> AttributedString {
        var text = AttributedString()
        for (index, line) in lines.enumerated() {
            var part = AttributedString(index == 0 ? line.text : "\n" + line.text)
            part.foregroundColor = line.isError ? StudioColors.danger : StudioColors.body
            text += part
        }
        return text
    }
}

/// Another app's check run: its title, and its summary in Markdown.
private struct CheckRunSummary: View {
    let output: PullRequestChecks.Output
    let open: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !output.title.isEmpty {
                Text(output.title)
                    .font(.studio(13, .semibold))
                    .foregroundStyle(StudioColors.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !output.summary.isEmpty {
                StudioMarkdownView(markdown: output.summary, size: 12.5, open: open)
            }
            if output.title.isEmpty && output.summary.isEmpty {
                Text("No summary.").font(.studio(12)).foregroundStyle(StudioColors.muted)
            }
        }
    }
}

/// A small spinner and what's being read.
private struct Reading: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.studio(12)).foregroundStyle(StudioColors.muted)
        }
    }
}

/// A check's outcome as the canvas marks it: a heavy green check, a red cross, an amber clock, a muted ring.
struct CheckOutcomeIcon: View {
    let outcome: PullRequestPage.Check.Outcome
    var size: CGFloat = 14

    var body: some View {
        switch outcome {
        case .passed: StudioIcon(.check, size: size, weight: 2.2).foregroundStyle(StudioColors.ok)
        case .failed: StudioIcon(.close, size: size, weight: 2.2).foregroundStyle(StudioColors.danger)
        case .running: StudioIcon(.clock, size: size).foregroundStyle(StudioColors.amber)
        case .skipped: StudioIcon(.circle, size: size).foregroundStyle(StudioColors.muted)
        }
    }
}
