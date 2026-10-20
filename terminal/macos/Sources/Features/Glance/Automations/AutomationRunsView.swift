import AppKit
import Combine
import GlanceCore
import GlanceKit
import SwiftUI

/// An automation's runs, newest first, kept current from the engine's activity. Run logs are read, decoded and
/// summarized on a background queue (a long run's log is never read on the main thread): only the runs that wrote
/// lines or changed state are read again, at most four times a second, and a result older than what is shown is
/// dropped.
@MainActor
final class AutomationRunsModel: ObservableObject {
    let id: String
    @Published private(set) var records: [RunRecord] = []
    /// True until the first read of the list lands.
    @Published private(set) var loading = true

    private let limit: Int
    private let queue = DispatchQueue(label: "dev.glance.automation-runs", qos: .userInitiated)
    /// Runs to read again, and whether the whole list is still to be read; both stay until a read covering them lands.
    private var pending: Set<String> = []
    private var full = true
    private var generation = 0
    private var appliedGeneration = 0
    private var scheduled = false
    private var lastLive: Set<String> = []
    private var watches: [AnyCancellable] = []

    init(id: String, limit: Int = 100) {
        self.id = id
        self.limit = limit
        let engine = AutomationEngine.shared
        lastLive = Self.liveRuns(engine, id)
        watches.append(engine.activity.sink { [weak self] activity in
            MainActor.assumeIsolated { self?.heard(activity) }
        })
        // A run that ends without a run.end line stops being live: read it again so it stops saying "running".
        watches.append(engine.$live.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.liveChanged() } }
        })
        read()
    }

    private static func liveRuns(_ engine: AutomationEngine, _ id: String) -> Set<String> {
        Set(engine.live.filter { $0.ref.automation == id }.map(\.ref.run))
    }

    private func heard(_ activity: AutomationActivity) {
        guard case .logged(let ref, _) = activity, ref.automation == id else { return }
        pending.insert(ref.run)
        schedule()
    }

    private func liveChanged() {
        let now = Self.liveRuns(AutomationEngine.shared, id)
        let changed = now.symmetricDifference(lastLive)
        lastLive = now
        guard !changed.isEmpty else { return }
        pending.formUnion(changed)
        schedule()
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduled = false
                self?.read()
            }
        }
    }

    /// Reads what is pending (or the whole list) off the main thread and publishes it when it lands, unless it is
    /// older than what is shown. Runs stay pending until a landed read covered them.
    private func read() {
        generation += 1
        let mine = generation
        let runs = pending
        let everything = full
        let live = Self.liveRuns(AutomationEngine.shared, id)
        let library = AutomationEngine.shared.library
        let id = id, limit = limit
        queue.async { [weak self] in
            let records = Self.records(library: library, id: id, runs: everything ? nil : runs, limit: limit,
                                       live: live)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Reads finish in the order they started; one that a newer read overtook is still newer than what is
                    // shown, so it lands (the list never waits on a read that keeps being superseded).
                    guard let self, mine > self.appliedGeneration else { return }
                    self.appliedGeneration = mine
                    self.apply(records, replacing: everything)
                    // Only what this read covered is done; a line heard since waits for the next read.
                    self.pending.subtract(runs)
                    if everything { self.full = false }
                    self.loading = false
                }
            }
        }
    }

    private func apply(_ read: [RunRecord], replacing: Bool) {
        var merged = replacing ? [] : records
        for record in read {
            if let index = merged.firstIndex(where: { $0.id == record.id }) {
                merged[index] = record
            } else {
                merged.append(record)
            }
        }
        merged.sort { $0.id > $1.id }
        records = Array(merged.prefix(limit))
    }

    /// The whole list (`runs` nil) or just these runs, summarized from their logs.
    nonisolated private static func records(library: AutomationLibrary, id: String, runs: Set<String>?, limit: Int,
                                            live: Set<String>) -> [RunRecord] {
        guard let runs else { return library.runs(id, limit: limit, live: live) }
        return runs.compactMap { run in
            RunLog.summarize(library.runLines(AutomationRunRef(automation: id, run: run)), id: run,
                             live: live.contains(run))
        }
    }
}

/// The automation tab's Runs (spec 2026-10-09-automations-design.md, "The UI"): the runs (status, trigger, start,
/// duration, cost) and the selected run's step timeline with each step's result, output and Claude's tool calls;
/// Re-run, Cancel while it runs, and Ask Claude about this run (A4's builder tab with the log), the view's one glow.
struct AutomationRunsView: View {
    let id: String
    @Binding var selection: String?
    let rerun: ([String: AutomationValue]) -> Void
    @StateObject private var model: AutomationRunsModel
    @ObservedObject private var engine = AutomationEngine.shared

    init(id: String, selection: Binding<String?>, rerun: @escaping ([String: AutomationValue]) -> Void) {
        self.id = id
        _selection = selection
        self.rerun = rerun
        _model = StateObject(wrappedValue: AutomationRunsModel(id: id))
    }

    private var current: RunRecord? {
        model.records.first { $0.id == selection } ?? model.records.first
    }

    var body: some View {
        if model.loading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading runs")
                    .font(.studio(12.5))
                    .foregroundStyle(StudioColors.muted)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if model.records.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("No runs yet")
                    .font(.studio(15, .semibold))
                    .foregroundStyle(StudioColors.ink)
                Text("Run it from the top bar, or let one of its triggers start it. Each run's steps, output and cost "
                     + "show here.")
                    .font(.studio(12.5))
                    .foregroundStyle(StudioColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 420, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            HStack(spacing: 0) {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.records, id: \.id) { record in
                            AutomationRunRow(record: record, selected: record.id == current?.id) {
                                selection = record.id
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(width: 280)
                Rectangle().fill(StudioColors.line).frame(width: 1)
                if let record = current {
                    detail(record)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    private func detail(_ record: RunRecord) -> some View {
        let ref = AutomationRunRef(automation: id, run: record.id)
        let live = engine.live.contains { $0.ref == ref }
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                AutomationRunHeader(record: record, ref: ref, live: live) { rerun(record.inputs) }
                if !record.inputs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Caption("Inputs")
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(record.inputs.keys.sorted(), id: \.self) { name in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(name)
                                        .font(.studioMono(12))
                                        .foregroundStyle(StudioColors.muted)
                                        .frame(width: 140, alignment: .leading)
                                    Text(record.inputs[name].map { $0 == .null ? "none" : $0.text } ?? "")
                                        .font(.studioMono(12))
                                        .foregroundStyle(StudioColors.ink)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Caption("Steps")
                    let agent = engine.entry(id)?.manifest?.isAgent == true
                    ForEach(AutomationTimeline.steps(record, manifest: engine.entry(id)?.manifest)) { step in
                        AutomationStepRow(step: step, ref: ref, live: live, tagged: agent)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .id(record.id)
    }
}

/// A run in the list: its status in words with its glyph, when it started, how it started, and its numbers.
private struct AutomationRunRow: View {
    let record: RunRecord
    let selected: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        let numbers = [AutomationRunText.duration(record.durationMs), AutomationRunText.cost(record.costUSD)]
            .filter { !$0.isEmpty }
        HStack(alignment: .top, spacing: 10) {
            AutomationStatusGlyph(tone: AutomationRunText.tone(record.status))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(AutomationRunText.status(record.status))
                        .font(.studio(12.5, .semibold))
                        .foregroundStyle(StudioColors.ink)
                    Spacer(minLength: 6)
                    Text(AutomationText.ago(record.startedAt, now: Date()))
                        .font(.studio(11.5))
                        .foregroundStyle(StudioColors.muted)
                }
                Text(AutomationRunText.trigger(record.trigger))
                    .font(.studio(11.5))
                    .foregroundStyle(StudioColors.muted)
                    .lineLimit(1)
                if !numbers.isEmpty {
                    Text(numbers.joined(separator: "   "))
                        .font(.studioMono(11))
                        .foregroundStyle(StudioColors.muted)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(selected ? StudioColors.selection : hovering ? StudioColors.hover : .clear))
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(perform: select)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
    }
}

/// The selected run: its status as the title, the facts in one sentence, and its actions.
private struct AutomationRunHeader: View {
    let record: RunRecord
    let ref: AutomationRunRef
    let live: Bool
    let rerun: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    AutomationStatusGlyph(tone: AutomationRunText.tone(record.status), size: 14)
                    Text(AutomationRunText.status(record.status))
                        .font(.studio(19, .bold))
                        .tracking(-0.19)
                        .foregroundStyle(StudioColors.ink)
                        .accessibilityAddTraits(.isHeader)
                }
                Text(facts)
                    .font(.studio(12))
                    .foregroundStyle(StudioColors.muted)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            StudioButton(title: "Log", icon: .file, style: .quiet) {
                NSWorkspace.shared.activateFileViewerSelecting([AutomationEngine.shared.logURL(ref)])
            }
            .help("Show the run's log in Finder")
            if live {
                StudioButton(title: "Cancel", icon: .close, style: .secondary) { AutomationEngine.shared.cancel(ref) }
            } else {
                StudioButton(title: "Re-run", icon: .refresh, style: .secondary, action: rerun)
            }
            if AutomationStudio.canAsk {
                GlowPill(title: "Ask Claude about this run") { AutomationStudio.askClaude(ref) }
            } else {
                StudioButton(title: "Ask Claude about this run", style: .quiet, enabled: false) {}
                    .help(AutomationStudio.builderMissing)
            }
        }
    }

    /// "By hand, started 9 Oct 2025 at 09:00, took 4.2 s, Claude $0.04, version 3".
    private var facts: String {
        var parts = [AutomationRunText.trigger(record.trigger),
                     "started \(record.startedAt.formatted(date: .abbreviated, time: .shortened))"]
        let duration = AutomationRunText.duration(record.durationMs)
        if !duration.isEmpty { parts.append("took \(duration)") }
        let cost = AutomationRunText.cost(record.costUSD)
        if !cost.isEmpty { parts.append("Claude \(cost)") }
        parts.append("version \(record.version)")
        return parts.joined(separator: ", ")
    }
}

/// A step of the timeline: glyph, id, how it went; Claude's tool calls; its result; its full output on request.
private struct AutomationStepRow: View {
    let step: AutomationTimelineStep
    let ref: AutomationRunRef
    let live: Bool
    /// An agent's page tags Claude's steps "Claude" and its ask steps "You".
    let tagged: Bool
    @State private var showsOutput = false

    var body: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    AutomationStatusGlyph(tone: step.tone)
                    Text(step.id)
                        .font(.studioMono(12.5, .semibold))
                        .foregroundStyle(step.phase == .notRun ? StudioColors.muted : StudioColors.ink)
                    if tagged, let kind = step.kind, kind == .claude || kind == .ask {
                        StepTag(title: kind == .claude ? "Claude" : "You")
                    }
                    Text(step.line)
                        .font(.studio(12))
                        .foregroundStyle(StudioColors.muted)
                    Spacer(minLength: 8)
                    if step.output != nil {
                        Button(showsOutput ? "Hide output" : "Output") { showsOutput.toggle() }
                            .buttonStyle(.plain)
                            .font(.studio(12, .medium))
                            .foregroundStyle(StudioColors.coralInk)
                    }
                }
                .accessibilityElement(children: .combine)
                if !step.tools.isEmpty {
                    FlowRow(spacing: 6) {
                        ForEach(step.tools, id: \.self) { MonoChip(name: $0) }
                    }
                }
                if let question = step.question, step.answer == nil, live, step.phase == .waiting {
                    AutomationAskPanel(ref: ref, question: question)
                } else if let question = step.question, let answer = step.answer {
                    AutomationAnsweredNote(question: question, answer: answer)
                }
                if !step.text.isEmpty && step.question == nil {
                    AutomationTextBlock(text: step.text, failed: step.phase == .failed)
                }
                if showsOutput, let output = step.output {
                    AutomationTextBlock(text: output)
                }
            }
            .padding(14)
        }
    }
}

/// "Claude" or "You" beside a step of an agent: the coral dot for Claude's, the person for the one the run waits on.
private struct StepTag: View {
    let title: String

    var body: some View {
        HStack(spacing: 4) {
            if title == "Claude" {
                Circle().fill(StudioColors.coral).frame(width: 6, height: 6)
            }
            Text(title)
                .font(.studio(10.5, .semibold))
                .foregroundStyle(StudioColors.body)
        }
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(Capsule().fill(StudioColors.chip))
        .accessibilityLabel("\(title) step")
    }
}

/// The question the run waits at (spec 2026-10-10-agents-design.md, "Studio"): its text and body, its choices as
/// buttons (⌥1–6 while this page is key) and, when the step takes one, a reply field. An answer resumes the run.
private struct AutomationAskPanel: View {
    let ref: AutomationRunRef
    let question: AutomationQuestion
    @State private var reply = ""
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question.question)
                .font(.studio(14, .semibold))
                .foregroundStyle(StudioColors.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let body = question.body {
                Text(body)
                    .font(.studio(12.5))
                    .foregroundStyle(StudioColors.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if !question.choices.isEmpty {
                FlowRow(spacing: 8) {
                    ForEach(Array(question.choices.enumerated()), id: \.offset) { index, choice in
                        StudioButton(title: choice, hint: "⌥\(index + 1)", style: index == 0 ? .primary : .secondary) {
                            send(AutomationAnswer.choice(index, of: question, via: .click))
                        }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .option)
                    }
                }
            }
            if question.allowsText {
                HStack(spacing: 8) {
                    TextField(question.choices.isEmpty ? "Your answer" : "Or type your own answer", text: $reply)
                        .textFieldStyle(.plain)
                        .font(.studio(12.5))
                        .foregroundStyle(StudioColors.ink)
                        .focused($focused)
                        .onSubmit { sendReply() }
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(StudioColors.field))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(focused ? StudioColors.coral : StudioColors.line, lineWidth: 1))
                    StudioButton(title: "Send", enabled: !reply.trimmingCharacters(in: .whitespaces).isEmpty) {
                        sendReply()
                    }
                }
            }
            if let problem {
                Text(problem)
                    .font(.studio(12))
                    .foregroundStyle(StudioColors.danger)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.selection))
        .accessibilityElement(children: .contain)
        .onAppear { if question.allowsText && question.choices.isEmpty { focused = true } }
    }

    private func sendReply() {
        send(AutomationAnswer.text(reply, for: question, via: .text))
    }

    private func send(_ answer: AutomationAnswer?) {
        guard let answer else {
            problem = "Pick one of the choices."
            return
        }
        problem = AutomationEngine.shared.answer(ref, answer) ? nil : "This run isn't waiting for an answer any more."
    }
}

/// Once answered: the question, and what was said.
private struct AutomationAnsweredNote: View {
    let question: AutomationQuestion
    let answer: AutomationAnswer

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(question.question)
                .font(.studio(12.5))
                .foregroundStyle(StudioColors.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text("You: \(answer.answer)")
                .font(.studio(12.5, .medium))
                .foregroundStyle(StudioColors.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}
