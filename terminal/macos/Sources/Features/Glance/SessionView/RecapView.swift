import AppKit
import GlanceCore
import SwiftUI

/// What a finished worktree shows in the Glance view instead of a timeline (spec §5 "Clicking a worktree"): what was
/// built, how it ended, and a way to start a new session on it or bring the last one back. Layout and values from the
/// signed-off replica (design-system/glance/prototype/sessionview.css, `.gv-recap*`).
struct RecapView: View {
    @ObservedObject var model: SessionViewModel
    let recap: WorktreeRecap
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The most commits the card lists; a merged PR can have hundreds.
    private static let commitsShown = 30

    private var branch: String { recap.branch ?? URL(fileURLWithPath: recap.worktree).lastPathComponent }
    private var hasContext: Bool { !(recap.bullets.isEmpty && recap.commits.isEmpty) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                card
                below
            }
            .sessionColumn()
            .padding(.vertical, 8)
        }
        .onAppear { model.assets.recapAppeared() }
        .onDisappear { model.assets.recapDisappeared() }
    }

    // MARK: The card

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Worktree recap").font(.studio(12, .semibold)).foregroundStyle(StudioColors.coralInk)
                Spacer(minLength: 8)
                if let active = recap.lastActive {
                    Text("last active \(ProofFormat.ago(active))").font(.studio(12, .medium)).foregroundStyle(StudioColors.muted)
                }
            }
            Text(recap.title).font(.studio(19, .bold)).foregroundStyle(StudioColors.ink)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8).padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            meta
            if model.recapLoading {
                HStack(spacing: 8) {
                    spinner
                    Text("Reading what was built…").font(.studio(13)).foregroundStyle(StudioColors.muted)
                }
                .frame(minHeight: 28)
                .padding(.top, 16)
                .accessibilityElement(children: .combine)
            } else {
                summary
                facts
                commits
                RecapAssetsStrip(assets: model.assets)
            }
        }
        .padding(.vertical, 20).padding(.horizontal, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(StudioColors.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(StudioColors.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private var spinner: some View {
        Group {
            if reduceMotion { Image(systemName: "ellipsis").font(.system(size: 12)) } else { ProgressView().controlSize(.small) }
        }
    }

    /// The folder and the branch, in mono.
    private var meta: some View {
        HStack(spacing: 6) {
            StudioIcon(.folder, size: 12)
            Text((recap.worktree as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                .help(recap.worktree)
            if recap.branch != nil {
                StudioIcon(.branch, size: 12).padding(.leading, 8)
                Text(branch).lineLimit(1).truncationMode(.middle)
            }
        }
        .font(.studioMono(11.5))
        .foregroundStyle(StudioColors.muted)
        .accessibilityElement(children: .combine)
    }

    // MARK: What was built

    @ViewBuilder private var summary: some View {
        if recap.bullets.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("No summary was stored for this worktree's sessions.")
                    .font(.studio(14)).foregroundStyle(StudioColors.body)
                summarizeButton
            }
            .padding(.top, 14)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(recap.bullets.enumerated()), id: \.offset) { _, bullet in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(StudioColors.muted).accessibilityHidden(true)
                        Text(Self.inline(bullet)).lineSpacing(15 * 0.6 - 4).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.studio(15))
            .foregroundStyle(StudioColors.body)
            .textSelection(.enabled)
            .padding(.top, 16)
        }
        // Some sessions summarized, others not: the button is still there for the rest.
        if !recap.bullets.isEmpty, !recap.unsummarized.isEmpty {
            summarizeButton.padding(.top, 10)
        }
        if let source = recap.source {
            HStack(spacing: 6) {
                StudioIcon(.docs, size: 12)
                Text(source).font(.studio(12))
            }
            .foregroundStyle(StudioColors.muted)
            .padding(.top, 10)
            .accessibilityElement(children: .combine)
        }
    }

    /// Claude runs only on this button: the newest few sessions that have a transcript and no summary, one at a time. It says
    /// how far it is, and how many are left to ask again for.
    @ViewBuilder private var summarizeButton: some View {
        let waiting = recap.unsummarized.count
        if waiting > 0 || model.summarizing {
            VStack(alignment: .leading, spacing: 6) {
                Button { model.summarize() } label: {
                    HStack(spacing: 6) {
                        if model.summarizing { spinner } else { Image(systemName: "sparkles") }
                        Text(buttonTitle(waiting))
                    }
                }
                .buttonStyle(EmptyButtonStyle(primary: false))
                .disabled(model.summarizing)
                .help("Claude reads the newest \(RecapText.summarizeBatch) sessions' transcripts, one at a time, and writes what got done")
                if waiting > RecapText.summarizeBatch, !model.summarizing {
                    Text("\(waiting) sessions have no summary. One click reads the newest \(RecapText.summarizeBatch).")
                        .font(.studio(12)).foregroundStyle(StudioColors.muted)
                }
            }
        }
    }

    private func buttonTitle(_ waiting: Int) -> String {
        if model.summarizing {
            guard let progress = model.summaryProgress else { return "Summarizing…" }
            return "Summarizing \(min(progress.done + 1, progress.total)) of \(progress.total)…"
        }
        return waiting > RecapText.summarizeBatch ? "Summarize the newest \(RecapText.summarizeBatch)" : "Summarize with Claude"
    }

    /// A summary's inline Markdown (code, emphasis) as text. Its links are dropped: a summary is model output, and nothing
    /// here opens a page.
    private static func inline(_ markdown: String) -> AttributedString {
        var text = (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
        for range in text.runs.filter({ $0.link != nil }).map(\.range) { text[range].link = nil }
        return text
    }

    // MARK: How it ended

    private var facts: some View {
        VStack(alignment: .leading, spacing: 0) {
            StudioColors.line2.frame(height: 1)
            HStack(alignment: .top, spacing: 12) {
                fact("Outcome") {
                    HStack(spacing: 8) {
                        ProofPillView(pill: recap.pill)
                        if let pr = recap.pr { BoardPRChip(pr: pr) }
                    }
                }
                fact("Changes") {
                    if let files = recap.files {
                        HStack(spacing: 5) {
                            Text("\(files) \(files == 1 ? "file" : "files")").foregroundStyle(StudioColors.ink)
                            Text("+\(recap.added)").foregroundStyle(StudioColors.ok)
                            Text("\u{2212}\(recap.removed)").foregroundStyle(StudioColors.danger)
                        }
                        .font(.studioMono(13, .medium))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(files) \(files == 1 ? "file" : "files"), \(recap.added) added, \(recap.removed) removed")
                    } else {
                        Text("Not known").font(.studio(13)).foregroundStyle(StudioColors.muted)
                    }
                }
                fact("Sessions") {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(recap.sessions.count.formatted() + (recap.older > 0 ? " newest" : "")
                                 + (recap.spend.map { " \u{00B7} " + Self.dollars($0) } ?? ""))
                                .font(.studio(13, .medium)).foregroundStyle(StudioColors.ink)
                            // The cost is read from the transcripts after the rest is shown.
                            if recap.spendPending { spinner.accessibilityLabel("Reading the cost") }
                        }
                        if recap.older > 0 {
                            Text("and \(recap.older) older, not counted").font(.studio(11.5)).foregroundStyle(StudioColors.muted)
                        }
                    }
                }
            }
            .padding(.top, 16)
        }
        .padding(.top, 20)
    }

    private func fact<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased()).font(.studio(11, .semibold)).tracking(0.66).foregroundStyle(StudioColors.muted)
            value()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func dollars(_ amount: Double) -> String { "$" + String(format: "%.2f", amount) }

    // MARK: Commits

    @ViewBuilder private var commits: some View {
        if !recap.commits.isEmpty {
            Text("COMMITS").font(.studio(11, .semibold)).tracking(0.66).foregroundStyle(StudioColors.muted)
                .padding(.top, 20).padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(recap.commits.prefix(Self.commitsShown).enumerated()), id: \.offset) { _, commit in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(commit.hash).font(.studioMono(12)).foregroundStyle(StudioColors.coralInk)
                        Text(commit.subject).font(.studio(13)).foregroundStyle(StudioColors.body)
                            .lineLimit(2).truncationMode(.tail)
                    }
                    .accessibilityElement(children: .combine)
                }
                if recap.commits.count > Self.commitsShown {
                    Text("and \(recap.commits.count - Self.commitsShown) more").font(.studio(12)).foregroundStyle(StudioColors.muted)
                }
            }
        }
    }

    // MARK: Under the card

    @ViewBuilder private var below: some View {
        if recap.exists {
            VStack(alignment: .leading, spacing: 6) {
                if hasContext || model.recapLoading {
                    Toggle("Include the recap as context", isOn: $model.recapAsContext)
                        .toggleStyle(.switch).controlSize(.small)
                        .font(.studio(12.5, .medium)).foregroundStyle(StudioColors.body)
                        .frame(minHeight: 28)
                        .padding(.horizontal, 4)
                        .help("The recap goes ahead of your first message, as background")
                }
                ComposerView(model: model, placeholder: "Start a new session on \(branch)…")
                resume
            }
        } else {
            removed
        }
        if let message = model.recapMessage {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 11, weight: .semibold)).padding(.top, 2)
                Text(message).font(.studio(12.5)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            .foregroundStyle(StudioColors.danger)
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Error: " + message)
        }
    }

    /// The quiet Resume button: always there, and when it can't be used it says why.
    private var resume: some View {
        let blocked = model.resumeBlocked
        return HStack(spacing: 10) {
            Button { model.resumeLast() } label: {
                Label("Resume last session", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(EmptyButtonStyle(primary: false))
            .disabled(blocked != nil)
            if let blocked {
                Text(blocked).font(.studio(12)).foregroundStyle(StudioColors.muted).fixedSize(horizontal: false, vertical: true)
            } else if let folder = model.resumeElsewhere {
                Text("Resumes in \((folder as NSString).abbreviatingWithTildeInPath)")
                    .font(.studio(12)).foregroundStyle(StudioColors.muted)
                    .lineLimit(1).truncationMode(.middle).help(folder)
            }
        }
    }

    /// A removed worktree can't take a session until it is back (spec §5): one click brings it back on its branch, unless the
    /// branch is gone too (usually deleted after the merge), when there is nothing to bring back and it says so.
    private var removed: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This worktree was removed.").font(.studio(14, .semibold)).foregroundStyle(StudioColors.ink)
            if recap.branchExists == false {
                Text("Its branch \(branch) is gone too, usually deleted after the merge, so it can't be recreated. Start a new worktree from Command to work on this again.")
                    .font(.studio(12.5)).foregroundStyle(StudioColors.muted).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("A new session needs its folder. Recreate it on \(branch) and it can start where this one stopped.")
                    .font(.studio(12.5)).foregroundStyle(StudioColors.muted).fixedSize(horizontal: false, vertical: true)
                Button { model.recreateWorktree() } label: {
                    HStack(spacing: 6) {
                        if model.recreating { spinner }
                        Text(model.recreating ? "Recreating…" : "Recreate worktree")
                    }
                }
                .buttonStyle(EmptyButtonStyle(primary: true))
                .disabled(model.recreating || model.recapLoading)
                .help("git worktree add \(recap.worktree) \(branch)")
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Assets

/// "Assets n" and the first four tiles under the commits (replica `.gv-recap-assets`), from the same model as the panel's
/// section: a worktree that is gone shows what its last session's records hold. A tile opens Quick Look; the rest are in
/// the panel.
private struct RecapAssetsStrip: View {
    @ObservedObject var assets: AssetsModel

    var body: some View {
        let strip = RecapAssets.strip(assets.items)
        if !strip.shown.isEmpty {
            HStack(spacing: 8) {
                Text("ASSETS").font(.studio(11, .semibold)).tracking(0.66).foregroundStyle(StudioColors.muted)
                Text("\(assets.items.count)").font(.studioMono(11)).monospacedDigit().foregroundStyle(StudioColors.muted)
            }
            .padding(.top, 20).padding(.bottom, 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Assets, \(assets.items.count)")
            .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: RecapAssets.tiles),
                      alignment: .leading, spacing: 10) {
                ForEach(strip.shown) { AssetTile(item: $0, detail: assets.detail(of: $0), scanning: assets.scanning) }
            }
            if strip.more > 0 {
                Text("and \(strip.more) more in the panel's Assets").font(.studio(12)).foregroundStyle(StudioColors.muted)
                    .padding(.top, 8)
            }
        }
    }
}
