import AppKit
import GlanceCore
import SwiftUI

/// The Proof section of the Glance view's right panel (replica: sessionview.js `SV_PANEL`, `.gv-proof`): what the
/// project's setup asks for, what Glance saw, what Claude says, and the actions that follow from it.
struct ProofPanelView: View {
    @ObservedObject var model: SessionViewModel
    @ObservedObject private var proof: ProofModel
    /// Only to show a group in Assets when a count is pressed; the counts come from the record.
    private let assets: AssetsModel
    /// A finished worktree's recap shows the last session's proof but doesn't act on it: no asking Claude, no publish, no merge.
    private let readOnly: Bool
    @State private var confirmingMerge = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: SessionViewModel, readOnly: Bool = false) {
        self.model = model
        self.readOnly = readOnly
        proof = model.proof
        assets = model.assets
    }

    /// Another session or folder is another card: a prompt sent for the old one must not latch the new one's button.
    private var followKey: String { "\(model.proofSession ?? "")|\(model.cwd ?? "")" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch proof.setup {
            case .missing:
                if proof.setupLoaded && readOnly {
                    quiet("This project has no proof setup, so there are no checks to show.")
                } else if proof.setupLoaded {
                    SetupCard(model: model, proof: proof).id(followKey)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 56)
                        .accessibilityLabel("Reading the proof setup")
                }
            case .invalid(let issues, _): BrokenSetupCard(model: model, proof: proof, issues: issues, readOnly: readOnly).id(followKey)
            case .valid(let setup, let root): valid(setup, root: root)
            }
            // Make explainer needs no setup (only its `command` does): it is reachable from any record, with a linked session.
            if StudioFeatures.shared.isOn(.commandCenter), let id = model.link?.sessionID {
                ExplainerSection(proof: proof, session: id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // A PR opened since, or CI turning red, shows up when the panel is looked at (throttled, off the main thread).
        .onAppear { proof.reload(); proof.refreshPRIfStale() }
        .onChange(of: proof.pr?.number) { _, _ in confirmingMerge = false }
    }

    // MARK: Valid setup

    @ViewBuilder private func valid(_ setup: ProofSetup, root: String) -> some View {
        head(root: root)
        gaps(setup)
        ProofSubhead(title: "Checks") { ProofBadge(source: .glance) }
        if setup.checks.isEmpty {
            quiet("The setup names no checks.")
        } else {
            ChecksGrid(record: proof.record, setup: setup, showsDetails: true)
        }
        if !setup.required.isEmpty {
            Text("Required: " + setup.required.map(ProofFormat.requirement).joined(separator: ", "))
                .font(.studio(11.5)).foregroundStyle(StudioColors.muted)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
        }
        previews
        if let record = proof.record {
            captures()
            notes(record, setup: setup)
            if !record.pending.isEmpty {
                ProofSubhead(title: "Pending") {
                    Text("\(record.pending.filter { !$0.done }.count) open").font(.studioMono(11)).foregroundStyle(StudioColors.muted)
                }
                PendingList(items: record.pending)
            }
            if let verdict = record.verdict {
                ProofSubhead(title: "Verdict") { ProofBadge(source: .claude) }
                VerdictBlock(verdict: verdict)
            }
        }
        foot
    }

    private func head(root: String) -> some View {
        HStack(spacing: 6) {
            Text(ProofSetupFile.relativePath).font(.studioMono(11.5)).foregroundStyle(StudioColors.muted)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Menu {
                if !readOnly { Button("Update setup with Claude") { model.composerDraft = ProofModel.Prompt.update } }
                Button("Open proof.json in Razor") { openSetup(root: root) }
                Button("Refresh") { proof.reload(); proof.refreshPR() }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(StudioColors.body)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Proof setup")
            .help("Proof setup")
        }
        .frame(minHeight: 28)
        .padding(.bottom, 4)
    }

    private func openSetup(root: String) {
        let path = (root as NSString).appendingPathComponent(ProofSetupFile.relativePath)
        guard let window = model.controller?.window ?? NSApp.keyWindow else { return }
        _ = GlanceEditorHost.openFromPane(path, from: window, directory: model.cwd)
    }

    // MARK: Gaps

    @ViewBuilder private func gaps(_ setup: ProofSetup) -> some View {
        let all = proof.gaps
        if proof.record?.checks.isEmpty ?? true {
            // Nothing has run in this session (it may only have browsed): no "not run yet" list, only what is true anyway.
            quiet("No checks recorded yet")
            GapList(gaps: all.filter { $0.level != .warn }, allClear: nil).padding(.top, 4)
        } else {
            GapList(gaps: all, allClear: setup.required.isEmpty ? "No required checks" : "Every required check passed")
        }
    }

    private func quiet(_ text: String) -> some View {
        Text(text).font(.studio(12.5)).foregroundStyle(StudioColors.muted)
            .fixedSize(horizontal: false, vertical: true).frame(minHeight: 28, alignment: .leading)
    }

    // MARK: Previews

    @ViewBuilder private var previews: some View {
        if !proof.previews.isEmpty {
            ProofSubhead(title: "Previews") { EmptyView() }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(proof.previews) { preview in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(preview.name).font(.studio(12.5, .medium)).foregroundStyle(StudioColors.ink)
                            .lineLimit(1).frame(maxWidth: 88, alignment: .leading)
                        switch preview.result {
                        case .success(let address): link(address)
                        case .failure(let failure):
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Image(systemName: "exclamationmark.triangle").font(.system(size: 11))
                                Text(failure.message).font(.studio(12)).lineLimit(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .foregroundStyle(StudioColors.danger.opacity(0.85))
                            .accessibilityElement(children: .combine)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 28, alignment: .leading)
                }
            }
        }
    }

    private func link(_ address: String) -> some View {
        Button {
            guard let url = URL(string: address) else { return }
            SessionTimelineView.openLink(url, window: model.controller?.window, directory: model.cwd)
        } label: {
            Text(address).font(.studioMono(11.5)).foregroundStyle(StudioColors.coralInk)
                .lineLimit(1).truncationMode(.middle).frame(minHeight: 28)
        }
        .buttonStyle(.plain)
        .help(address)
        .accessibilityLabel("Open preview \(address)")
    }

    // MARK: Captures

    /// One line, "3 Outcome · 5 Testing": the same items Assets lists, each count a button that shows that group there.
    @ViewBuilder private func captures() -> some View {
        // Captures only: a finished explainer is under Outcome in Assets and nowhere in Proof.
        let counts = AssetGroups.proofCounts(captures: proof.record?.captures ?? [])
        let outcomes = counts.outcome
        let testing = counts.testing
        if outcomes + testing > 0 {
            ProofSubhead(title: "Captures") {
                Text("\(outcomes + testing)").font(.studioMono(11)).foregroundStyle(StudioColors.muted)
            }
            HStack(spacing: 4) {
                if outcomes > 0 { purposeCount(.outcome, outcomes) }
                if outcomes > 0, testing > 0 { Text("·").font(.studio(12)).foregroundStyle(StudioColors.muted).accessibilityHidden(true) }
                if testing > 0 { purposeCount(.testing, testing) }
                Spacer(minLength: 0)
            }
        }
    }

    private func purposeCount(_ group: AssetItem.Group, _ count: Int) -> some View {
        Button { assets.show(group: group) } label: {
            HStack(spacing: 4) {
                Image(systemName: group.symbol).font(.system(size: 11, weight: .semibold))
                Text("\(count) \(group.label)").font(.studio(12, .medium))
            }
            .foregroundStyle(group.tint)
            .padding(.horizontal, 6)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle())
        .accessibilityLabel("\(count) \(group.label)")
        .accessibilityHint("Shows them in Assets")
    }

    // MARK: Notes

    @ViewBuilder private func notes(_ record: WorkRecord, setup: ProofSetup) -> some View {
        let loose = record.notes.filter { ($0.section ?? "").isEmpty }
        if !loose.isEmpty {
            ProofSubhead(title: "What happened") { ProofBadge(source: .claude) }
            NoteList(notes: loose)
        }
        // The setup's sections in its order, then any other section a note names (a note must never vanish).
        let named = record.notes.compactMap { note -> String? in (note.section ?? "").isEmpty ? nil : note.section }
        let sections = setup.sections + named.reduce(into: [String]()) { if !setup.sections.contains($1) && !$0.contains($1) { $0.append($1) } }
        ForEach(sections, id: \.self) { name in
            let list = record.notes.filter { $0.section == name }
            if !list.isEmpty {
                ProofSubhead(title: name) { ProofBadge(source: .claude) }
                NoteList(notes: list)
            }
        }
    }

    // MARK: Foot

    private var prOpen: ProofPR.Info? {
        guard let pr = proof.pr, pr.state == "OPEN", !pr.merged else { return nil }
        return pr
    }

    @ViewBuilder private var foot: some View {
        let ready = proof.pill == .ready
        VStack(alignment: .leading, spacing: 6) {
            if let pr = prOpen, !readOnly {
                if ready {
                    if confirmingMerge { mergeConfirm(pr) } else {
                        HStack(spacing: 6) {
                            Button { confirmingMerge = true } label: { Label("Merge #\(pr.number)", systemImage: "arrow.triangle.merge") }
                                .buttonStyle(EmptyButtonStyle(primary: true))
                            if !pr.repository.isEmpty {
                                Button { openPR(pr) } label: { Label("Open PR", systemImage: "arrow.triangle.pull") }
                                    .buttonStyle(EmptyButtonStyle(primary: false))
                            }
                        }
                        .disabled(proof.busy != nil)
                    }
                }
                if proof.record != nil {
                    Button { proof.publish() } label: {
                        Label("Publish summary to #\(pr.number)", systemImage: "square.and.arrow.up")
                            .font(.studio(12)).foregroundStyle(StudioColors.body)
                            .padding(.horizontal, 8).frame(minHeight: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(proof.busy != nil)
                    .padding(.leading, -8)
                    .help("Writes this summary into the PR's description, between its markers")
                }
            }
            if let busy = proof.busy {
                HStack(spacing: 6) {
                    if reduceMotion { Image(systemName: "ellipsis").font(.system(size: 11)) }
                    else { ProgressView().controlSize(.small) }
                    Text(busy).font(.studio(12)).foregroundStyle(StudioColors.muted)
                }
                .frame(minHeight: 28)
                .accessibilityElement(children: .combine)
            } else if let message = proof.message {
                HStack(alignment: .top, spacing: 6) {
                    if message.isError {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 11, weight: .semibold)).padding(.top, 2)
                    }
                    // A long gh error stays three lines; the whole text is in the tooltip.
                    Text(message.text).font(.studio(12)).lineLimit(3).truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(message.isError ? StudioColors.danger : StudioColors.body)
                .help(message.text)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel((message.isError ? "Error: " : "") + message.text)
                .task(id: message) {
                    try? await Task.sleep(nanoseconds: message.isError ? 30_000_000_000 : 8_000_000_000)
                    if !Task.isCancelled, proof.message == message { proof.message = nil }
                }
            }
        }
        .padding(.top, 16)
        // The merge asked about is gone (merged, closed, no longer Ready): ask again next time.
        .onChange(of: ready && prOpen != nil) { _, allowed in if !allowed { confirmingMerge = false } }
    }

    /// Merging can't be undone from here, so it asks, naming the PR and where it goes. Escape cancels; Return does not merge.
    private func mergeConfirm(_ pr: ProofPR.Info) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Merge #\(pr.number)\(pr.base.isEmpty ? "" : " into \(pr.base)")?")
                .font(.studio(13, .semibold)).foregroundStyle(StudioColors.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Runs gh pr merge --merge" + (pr.head.isEmpty ? "" : " for \(pr.head)") + ". Glance can't undo it.")
                .font(.studio(12)).foregroundStyle(StudioColors.body).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("Merge #\(pr.number)") { confirmingMerge = false; proof.merge() }
                    .buttonStyle(EmptyButtonStyle(primary: true))
                Button("Cancel") { confirmingMerge = false }
                    .buttonStyle(EmptyButtonStyle(primary: false)).keyboardShortcut(.cancelAction)
            }
            .disabled(proof.busy != nil)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(StudioColors.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(StudioColors.line3, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private func openPR(_ pr: ProofPR.Info) {
        PullRequestWindowController.open(repository: pr.repository, number: pr.number, root: model.cwd,
                                         from: model.controller?.window ?? NSApp.keyWindow)
    }
}

// MARK: - Make explainer

/// Make explainer (replica: sessionview.js `SV.explainerCard`). The button; while it runs, its step, progress and Cancel;
/// when it failed, where and why, the log and Retry. A finished explainer shows nothing here: it is under Outcome in Assets.
private struct ExplainerSection: View {
    @ObservedObject var proof: ProofModel
    let session: String
    @ObservedObject private var run = ExplainerRun.shared
    @State private var showingLog = false

    private var state: ExplainerState? { run.live[session] ?? proof.record?.explainer }
    private var shown: ExplainerState.Phase? { state?.shown(active: run.isActive(session: session)) }

    var body: some View {
        Group {
            switch shown {
            case .running?:
                if let state { ProofSubhead(title: "Video") { EmptyView() }; running(state) }
            case .failed?:
                if let state { ProofSubhead(title: "Video") { EmptyView() }; failed(state) }
            case .done?, nil:
                Button { proof.makeExplainer() } label: { Label("Make video", systemImage: "film") }
                    .buttonStyle(EmptyButtonStyle(primary: false))
                    .padding(.top, 16)
                    .help("Claude writes the scenes from this session's work; Studio narrates and renders them on this Mac")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: session) { _, _ in showingLog = false }
    }

    private static let steps: [ExplainerStep] = ExplainerStep.allCases

    /// 0...1 over the four steps, when the step measures itself.
    private func overall(_ state: ExplainerState) -> Double? {
        guard let progress = state.progress, let index = Self.steps.firstIndex(of: state.step) else { return nil }
        return (Double(index) + progress) / Double(Self.steps.count)
    }

    private func running(_ state: ExplainerState) -> some View {
        let fraction = overall(state)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "film").font(.system(size: 12, weight: .semibold)).foregroundStyle(StudioColors.coralInk)
                Text("Making video").font(.studio(13, .semibold)).foregroundStyle(StudioColors.ink)
                if let fraction {
                    Text("\(Int((fraction * 100).rounded()))%").font(.studioMono(12)).foregroundStyle(StudioColors.muted)
                }
                Spacer(minLength: 8)
                Button("Cancel") { run.cancel(session: session) }
                    .buttonStyle(EmptyButtonStyle(primary: false))
                    .help("Stop making the video")
            }
            ExplainerBar(fraction: fraction)
            stepList(state, failed: false)
            Text("\(ExplainerRun.name(state.step)). You can keep working; it shows in Assets when it's done.")
                .font(.studio(12)).foregroundStyle(StudioColors.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(StudioColors.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(StudioColors.line3, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Making video, \(ExplainerRun.name(state.step))" + (fraction.map { ", \(Int(($0 * 100).rounded())) percent" } ?? ""))
    }

    private func failed(_ state: ExplainerState) -> some View {
        // A run recorded as running that nothing runs now was cut off by a quit or a crash.
        let interrupted = state.phase == .running
        let lines = (state.log ?? "").split(separator: "\n", omittingEmptySubsequences: true)
        let reason = interrupted ? "Studio was closed or restarted while the video was being made." : (lines.first.map(String.init) ?? "")
        return VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(interrupted ? "Video was interrupted at \(ExplainerRun.name(state.step))" : "Video failed at \(ExplainerRun.name(state.step))")
                    .font(.studio(13, .semibold)).foregroundStyle(StudioColors.ink).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 12, weight: .semibold)).foregroundStyle(StudioColors.danger)
            }
            if !reason.isEmpty {
                Text(reason).font(.studio(12.5)).lineSpacing(3).foregroundStyle(StudioColors.body)
                    .lineLimit(6).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            stepList(state, failed: true)
            if let log = state.log, !log.isEmpty {
                Button { showingLog.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showingLog ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold))
                        Text(showingLog ? "Hide log" : "Show log").font(.studio(12))
                    }
                    .foregroundStyle(StudioColors.body).frame(minHeight: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(showingLog ? "expanded" : "collapsed")
                if showingLog {
                    ScrollView {
                        Text(log).font(.studioMono(11.5)).foregroundStyle(StudioColors.body).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(StudioColors.field))
                }
            }
            Button { proof.makeExplainer() } label: { Label("Retry", systemImage: "arrow.clockwise") }
                .buttonStyle(EmptyButtonStyle(primary: true))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(StudioColors.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(StudioColors.danger.opacity(0.45), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    /// Writing, Narrating, Rendering, Muxing: done ones ticked, the current one marked (a cross when it failed).
    private func stepList(_ state: ExplainerState, failed: Bool) -> some View {
        let now = Self.steps.firstIndex(of: state.step) ?? 0
        return HStack(spacing: 10) {
            ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                HStack(spacing: 3) {
                    if index < now {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(StudioColors.ok)
                    } else if index == now {
                        Image(systemName: failed ? "xmark" : "circle.fill").font(.system(size: failed ? 10 : 6, weight: .bold))
                            .foregroundStyle(failed ? StudioColors.danger : StudioColors.coralInk)
                    }
                    Text(ExplainerRun.name(step)).font(.studio(11.5, index == now ? .semibold : .regular))
                        .foregroundStyle(index > now ? StudioColors.muted : StudioColors.ink)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(ExplainerRun.name(step) + (index < now ? ", done" : index == now ? (failed ? ", failed" : ", now") : ""))
            }
        }
    }
}

/// The explainer's progress bar: a track and a coral fill; without a fraction (the step has no measure) a quiet full track.
private struct ExplainerBar: View {
    let fraction: Double?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(StudioColors.chip)
                Capsule().fill(StudioColors.coral).opacity(fraction == nil ? 0.25 : 1)
                    .frame(width: geometry.size.width * (fraction ?? 1))
            }
        }
        .frame(height: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue(fraction.map { "\(Int(($0 * 100).rounded())) percent" } ?? "no measure yet")
    }
}

// MARK: - Setup states

/// The project has no `.glance/proof.json`: Claude writes it.
private struct SetupCard: View {
    @ObservedObject var model: SessionViewModel
    @ObservedObject var proof: ProofModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This project isn't set up for proof yet").font(.studio(13, .semibold)).foregroundStyle(StudioColors.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Claude reads this repo (scripts, CI, deploy config), asks what it can't tell, and writes \(Text(ProofSetupFile.relativePath).font(.studioMono(11.5))). Then Glance records checks and captures by itself.")
                .font(.studio(12.5)).lineSpacing(3).foregroundStyle(StudioColors.body)
                .fixedSize(horizontal: false, vertical: true)
            AskClaudeButton(model: model, proof: proof, title: "Set up with Claude", prompt: ProofModel.Prompt.setUp)
                .padding(.top, 4)
        }
        .proofCard(tint: nil)
    }
}

/// `.glance/proof.json` exists and doesn't parse or doesn't hold together: the first problem, with its line.
private struct BrokenSetupCard: View {
    @ObservedObject var model: SessionViewModel
    @ObservedObject var proof: ProofModel
    let issues: [ProofSetupIssue]
    var readOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("proof.json has a problem").font(.studio(13, .semibold)).foregroundStyle(StudioColors.ink)
            } icon: {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 12, weight: .semibold)).foregroundStyle(StudioColors.danger)
            }
            if let issue = issues.first {
                Text(issue.line.map { "Line \($0): \(issue.message)" } ?? issue.message)
                    .font(.studio(12.5)).lineSpacing(3).foregroundStyle(StudioColors.body)
                    .fixedSize(horizontal: false, vertical: true)
                if let excerpt = issue.excerpt, !excerpt.isEmpty {
                    Text(issue.line.map { "\($0)  \(excerpt)" } ?? excerpt)
                        .font(.studioMono(11.5)).foregroundStyle(StudioColors.body).lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(StudioColors.field))
                }
            }
            if issues.count > 1 {
                Text("and \(issues.count - 1) more").font(.studio(12)).foregroundStyle(StudioColors.muted)
            }
            if let issue = issues.first, !readOnly {
                AskClaudeButton(model: model, proof: proof, title: "Fix with Claude", prompt: ProofModel.Prompt.fix(issue))
                    .padding(.top, 4)
            }
        }
        .proofCard(tint: StudioColors.danger)
    }
}

/// Sends one prompt to Claude, once: after it is sent the button waits ("Sent to Claude…") until the setup changes or
/// Claude finishes its turn, so a second click can't send it twice. A session that won't take input says so.
private struct AskClaudeButton: View {
    @ObservedObject var model: SessionViewModel
    @ObservedObject var proof: ProofModel
    let title: String
    let prompt: String
    @State private var sent = false
    @State private var sawWorking = false
    @State private var refused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                refused = false
                if model.askClaude(prompt) {
                    sent = true
                    sawWorking = model.timeline.live.working
                } else {
                    refused = true
                }
            } label: { Label(title, systemImage: "sparkles") }
                .buttonStyle(EmptyButtonStyle(primary: true))
                .opacity(sent ? 0.55 : 1)
                .disabled(sent)
            if sent {
                Text("Sent to Claude…").font(.studio(12)).foregroundStyle(StudioColors.muted)
            } else if refused {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 11, weight: .semibold)).padding(.top, 2)
                    Text("This session isn't accepting input right now.").font(.studio(12))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(StudioColors.danger)
            }
        }
        .onChange(of: model.timeline.live.working) { _, working in
            guard sent else { return }
            if working { sawWorking = true } else {
                // A prompt still queued behind a running turn hasn't started: wait for a turn of its own.
                if !model.queued.isEmpty { sawWorking = false }
                release()
            }
        }
        .onChange(of: model.queued) { _, _ in release() }
        .onChange(of: proof.setup) { _, _ in sent = false; refused = false }
        // A turn that never shows as working must not leave the button dead.
        .task(id: "\(sent)|\(sawWorking)") {
            guard sent else { return }
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            // Only a prompt whose turn never showed is let go; a long turn keeps the latch until it ends.
            if !Task.isCancelled, !sawWorking, !model.timeline.live.working { sent = false }
        }
    }

    /// The turn that took the prompt has ended and nothing of ours is still queued.
    private func release() {
        if sent, sawWorking, !model.timeline.live.working, model.queued.isEmpty { sent = false }
    }
}

private extension View {
    func proofCard(tint: Color?) -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(StudioColors.card))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint?.opacity(0.45) ?? StudioColors.line3, lineWidth: 1))
            .padding(.top, 2)
    }
}

// MARK: - Captures

// MARK: - Section summary

/// The pill in the section's header. Its own view so that it follows the proof (the panel's section header is built
/// from the session view model alone).
struct ProofSectionSummary: View {
    @ObservedObject var proof: ProofModel

    var body: some View {
        if proof.setup.setup != nil { ProofPillView(pill: proof.pill) }
    }
}
