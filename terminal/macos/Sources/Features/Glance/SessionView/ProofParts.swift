import SwiftUI
import GlanceCore

// The small parts of proof the Glance view shares: where an entry came from, and the verdict pill. Values from the
// replica (design-system/glance/prototype/sessionview.css `.gv-badge`, `.gv-pill`).

/// "Seen by Glance" (a check or capture Glance watched happen) or "Claude says" (reported through the proof tools).
struct ProofBadge: View {
    let source: ProofSource

    var body: some View {
        Text(label)
            .font(.studio(11, .semibold)).kerning(0.2)
            .foregroundStyle(source == .glance ? StudioColors.tealInk : StudioColors.coralInk)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .overlay(Capsule().stroke((source == .glance ? StudioColors.tealInk : StudioColors.coralInk).opacity(0.4), lineWidth: 1))
            .fixedSize()
            .help(source == .glance ? "Glance saw this happen" : "Claude reported this through the proof tools")
    }

    private var label: String { source == .glance ? "Seen by Glance" : "Claude says" }
}

/// The session's verdict: a glyph and its words, never colour alone.
struct ProofPillView: View {
    let pill: ProofPill

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold))
            Text(pill.label).font(.studio(11.5, .semibold)).lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.leading, 7).padding(.trailing, 9).frame(height: 22)
        .background(Capsule().fill(fill))
        .overlay(Capsule().stroke(tint.opacity(0.4), lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Proof of work: \(pill.label)")
        .help("Computed from the checks Glance saw and what Claude reported")
    }

    private var symbol: String {
        switch pill {
        case .ready: "checkmark"
        case .merged: "arrow.triangle.merge"
        case .needsWork: "xmark"
        case .notTested: "minus"
        case .inProgress: "ellipsis"
        }
    }

    private var tint: Color {
        switch pill {
        case .ready: StudioColors.ok
        case .merged: StudioColors.syntaxType
        case .needsWork: StudioColors.danger
        case .notTested: StudioColors.muted
        case .inProgress: StudioColors.tealInk
        }
    }

    private var fill: Color {
        switch pill {
        case .ready: StudioColors.okFill
        case .merged: StudioColors.syntaxType.opacity(0.12)
        case .needsWork: StudioColors.dangerFill
        case .notTested: .clear
        case .inProgress: StudioColors.tealFill
        }
    }
}

/// The strip under a check's command line: `✓ 42 passed · Local`, with the badge on the right.
struct ProofCheckStrip: View {
    let run: ProofCheckRun

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: run.ok ? "checkmark" : "xmark")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(StudioColors.onCoral)
                .frame(width: 20, height: 20)
                .background(Circle().fill(run.ok ? StudioColors.ok : StudioColors.danger))
                .accessibilityHidden(true)
            Text(run.name).font(.studio(13, .medium)).foregroundStyle(StudioColors.ink).lineLimit(1)
            Text("·").foregroundStyle(StudioColors.muted)
            Text(summary).font(.studioMono(12, .medium)).foregroundStyle(StudioColors.body).lineLimit(1)
            Spacer(minLength: 8)
            ProofBadge(source: run.source)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(run.ok ? StudioColors.okFill : StudioColors.dangerFill))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke((run.ok ? StudioColors.ok : StudioColors.danger).opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(run.name): \(summary). \(run.source == .glance ? "Seen by Glance" : "Claude says")")
    }

    /// "42 passed · Local", "2 failed · Unknown environment", "Passed · Local".
    private var summary: String {
        let result: String
        if run.ok { result = run.passed.map { "\($0) passed" } ?? "Passed" }
        else { result = run.failed.map { "\($0) failed" } ?? "Failed" }
        return result + " · " + (run.environment ?? "Unknown environment")
    }
}

/// Claude says the tests pass and Glance saw no matching run (replica `.gv-claim`).
struct ProofClaimFlag: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StudioColors.danger)
            Text("No matching test run seen").font(.studio(12.5, .medium)).foregroundStyle(StudioColors.ink)
            Spacer(minLength: 8)
            ProofBadge(source: .glance)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(StudioColors.dangerFill))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioColors.danger.opacity(0.4), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .help("Glance saw no matching check run in this session")
    }
}

// MARK: - The Proof panel's parts (shared with the pull request card)

enum ProofFormat {
    /// "4.2 s", "38 s", "2 m 5 s"; nil for a time that can't be right.
    static func duration(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        if seconds < 10 { return String(format: "%.1f s", seconds) }
        if seconds < 60 { return "\(Int(seconds.rounded())) s" }
        return "\(Int(seconds) / 60) m \(Int(seconds) % 60) s"
    }

    /// "just now", "3m ago", "2h ago".
    static func ago(_ date: Date) -> String {
        let text = ClaudeProjectFolder.ago(date)
        return text == "now" ? "just now" : text + " ago"
    }

    /// "Unit@Local" read as words: "Unit on Local".
    static func requirement(_ text: String) -> String { text.replacingOccurrences(of: "@", with: " on ") }
}

/// A small-caps heading inside the panel (`.gv-sub`) with its badge or count on the right.
struct ProofSubhead<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title.uppercased()).font(.studio(11, .semibold)).kerning(0.6).foregroundStyle(StudioColors.muted)
                .lineLimit(1)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.top, 16).padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// What a gap list says: blocking gaps boxed in danger, missing runs in amber, then the quiet facts as chips.
struct GapList: View {
    let gaps: [ProofGap]
    /// Said when nothing is wrong; nil says nothing.
    var allClear: String? = "Every required check passed"

    var body: some View {
        let problems = gaps.filter { $0.level != .info }
        let facts = gaps.filter { $0.level == .info }
        VStack(alignment: .leading, spacing: 8) {
            if !problems.isEmpty {
                VStack(spacing: 4) {
                    ForEach(Array(problems.enumerated()), id: \.offset) { _, gap in row(gap) }
                }
            } else if let allClear {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy))
                    Text(allClear).font(.studio(12.5, .medium)).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(StudioColors.ok)
                .frame(minHeight: 28, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
            if !facts.isEmpty {
                FlowRow(spacing: 6) {
                    ForEach(Array(facts.enumerated()), id: \.offset) { _, gap in
                        Text(gap.text).font(.studio(11.5)).foregroundStyle(StudioColors.muted).lineLimit(1)
                            .padding(.horizontal, 8).frame(minHeight: 22)
                            .overlay(Capsule().stroke(StudioColors.line3, lineWidth: 1))
                    }
                }
            }
        }
    }

    private func row(_ gap: ProofGap) -> some View {
        let critical = gap.level == .crit
        let tint = critical ? StudioColors.danger : StudioColors.amber
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: critical ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(tint).padding(.top, 2)
            Text(gap.text).font(.studio(12.5, .medium)).foregroundStyle(StudioColors.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 6).frame(minHeight: 28)
        .background(RoundedRectangle(cornerRadius: 8).fill(critical ? StudioColors.dangerFill : StudioColors.amberFill.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(critical ? 0.45 : 0.35), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((critical ? "Blocking: " : "Warning: ") + gap.text)
    }
}

/// Check x environment: the latest run of each, a glyph and a word for every state. A run opens its details.
struct ChecksGrid: View {
    let record: WorkRecord?
    let setup: ProofSetup
    /// Called with the run when a cell is chosen. Nil (with `showsDetails` off) makes the cells plain marks.
    var onSelect: ((ProofCheckRun) -> Void)? = nil
    /// A chosen cell opens a popover with the run's command, counts and output.
    var showsDetails = false

    private struct Column: Identifiable {
        var title: String
        /// Runs whose environment is none of the setup's names.
        var isOther = false
        var id: String { isOther ? "\u{0}other" : title }
    }

    private var columns: [Column] {
        let names = Set(setup.environments.map(\.name))
        var out = setup.environments.map { Column(title: $0.name) }
        let checks = Set(setup.checks.map(\.name))
        let strays = record?.checks.contains { checks.contains($0.name) && !($0.environment.map(names.contains) ?? false) } == true
        if strays || out.isEmpty { out.append(Column(title: out.isEmpty ? "Run" : "Other", isOther: true)) }
        return out
    }

    private func run(_ check: String, _ column: Column) -> ProofCheckRun? {
        guard let record else { return nil }
        if !column.isOther { return ProofReview.latest(record, name: check, environment: column.title) }
        let names = Set(setup.environments.map(\.name))
        return record.checks.filter { $0.name == check && !($0.environment.map(names.contains) ?? false) }
            .reduce(nil) { best, next in best.map { next.at >= $0.at ? next : $0 } ?? next }
    }

    var body: some View {
        let columns = columns
        let wide = columns.count > 4
        // Room for a name like "Production" on two lines; more environments get narrower columns.
        let width: CGFloat = columns.count <= 2 ? 72 : columns.count == 3 ? 60 : columns.count == 4 ? 52 : 64
        let content = VStack(spacing: 0) {
            HStack(spacing: 4) {
                Color.clear.frame(maxWidth: wide ? nil : .infinity).frame(width: wide ? 96 : nil, height: 1)
                ForEach(columns) { column in
                    Text(column.title).font(.studio(11, .medium)).foregroundStyle(StudioColors.muted)
                        .lineLimit(2).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        .frame(width: width).help(column.title)
                }
            }
            .padding(.bottom, 4)
            ForEach(Array(setup.checks.enumerated()), id: \.offset) { index, check in
                HStack(spacing: 4) {
                    Text(check.name).font(.studio(12.5, .medium)).foregroundStyle(StudioColors.ink)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: wide ? nil : .infinity, alignment: .leading)
                        .frame(width: wide ? 96 : nil, alignment: .leading)
                        .help(check.name)
                    ForEach(columns) { column in
                        ProofCell(check: check.name, environment: column.title, run: run(check.name, column),
                                  onSelect: onSelect, showsDetails: showsDetails)
                            .frame(width: width)
                    }
                }
                .frame(minHeight: 32)
                .overlay(alignment: .top) { Rectangle().fill(index == 0 ? StudioColors.line : StudioColors.line2).frame(height: 1) }
            }
        }
        if wide { ScrollView(.horizontal, showsIndicators: false) { content } } else { content }
    }
}

private struct ProofCell: View {
    let check: String
    let environment: String
    let run: ProofCheckRun?
    let onSelect: ((ProofCheckRun) -> Void)?
    let showsDetails: Bool
    @State private var showing = false

    var body: some View {
        if let run {
            let word = run.ok ? "passed" : "failed"
            if onSelect != nil || showsDetails {
                Button {
                    onSelect?(run)
                    if showsDetails { showing.toggle() }
                } label: { mark(run.ok ? "checkmark" : "xmark", run.ok ? StudioColors.ok : StudioColors.danger,
                                run.ok ? StudioColors.okFill : StudioColors.dangerFill) }
                .buttonStyle(.plain)
                .popover(isPresented: $showing, arrowEdge: .bottom) {
                    ProofRunDetail(run: run, title: "\(check) on \(environment)")
                }
                .accessibilityLabel("\(check) on \(environment): \(word)")
                .accessibilityHint(showsDetails ? "Shows the command and output" : "")
            } else {
                mark(run.ok ? "checkmark" : "xmark", run.ok ? StudioColors.ok : StudioColors.danger,
                     run.ok ? StudioColors.okFill : StudioColors.dangerFill)
                    .help(run.command)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(check) on \(environment): \(word)")
            }
        } else {
            mark("minus", StudioColors.muted, .clear)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(check) on \(environment): not run")
        }
    }

    private func mark(_ symbol: String, _ tint: Color, _ fill: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 12, weight: .heavy)).foregroundStyle(tint)
            .frame(width: 32, height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(fill))
            .contentShape(Rectangle())
    }
}

/// One run in a popover: what ran, how it came out, and the end of its output.
struct ProofRunDetail: View {
    let run: ProofCheckRun
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: run.ok ? "checkmark" : "xmark").font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(run.ok ? StudioColors.ok : StudioColors.danger).accessibilityHidden(true)
                Text(title).font(.studio(13, .semibold)).foregroundStyle(StudioColors.ink).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(run.command).font(.studioMono(11.5)).foregroundStyle(StudioColors.body)
                .lineLimit(4).truncationMode(.middle).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled).help(run.command)
            Text(meta).font(.studio(11.5)).foregroundStyle(StudioColors.muted)
            tail
            ProofBadge(source: run.source)
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
    }

    /// "40 passed · 2 failed · 4.2 s · 3m ago"; a run with no counts says only how it came out.
    private var meta: String {
        var parts: [String] = []
        if let passed = run.passed { parts.append("\(passed) passed") }
        if let failed = run.failed, failed > 0 { parts.append("\(failed) failed") }
        if parts.isEmpty { parts.append(run.ok ? "Passed" : "Failed") }
        if let duration = run.duration.flatMap(ProofFormat.duration) { parts.append(duration) }
        parts.append(ProofFormat.ago(run.at))
        return parts.joined(separator: " · ")
    }

    /// The last 6 lines show; the whole stored tail scrolls.
    @ViewBuilder private var tail: some View {
        let text = run.outputTail.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            Text("No output recorded").font(.studio(11.5)).foregroundStyle(StudioColors.muted)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text).font(.studioMono(11)).foregroundStyle(StudioColors.body)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        .padding(8)
                    Color.clear.frame(height: 0).id("end")
                }
                .frame(height: 6 * 15 + 16)
                .background(RoundedRectangle(cornerRadius: 6).fill(StudioColors.field))
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            .accessibilityLabel("Output")
        }
    }
}

private struct ProofNoteRow: View {
    let kind: ProofNote.Kind?
    let text: String
    let done: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            glyph.frame(width: 16, height: 18)
            Text(text).font(.studio(12.5)).foregroundStyle(done ? StudioColors.muted : StudioColors.body)
                .strikethrough(done)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 22)
    }

    @ViewBuilder private var glyph: some View {
        switch kind {
        case .resolved: Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(StudioColors.ok)
        case .problem: Image(systemName: "exclamationmark").font(.system(size: 11, weight: .bold)).foregroundStyle(StudioColors.amber)
        default: Circle().fill(StudioColors.muted).frame(width: 4, height: 4)
        }
    }
}

/// Claude's notes. A note's kind is a glyph and the words beside it say the rest; the kind is spoken too.
struct NoteList: View {
    let notes: [ProofNote]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(notes) { note in
                ProofNoteRow(kind: note.kind, text: note.text, done: false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(note.kind.rawValue): \(note.text)")
            }
        }
    }
}

struct PendingList: View {
    let items: [ProofPending]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: item.done ? "checkmark.square.fill" : "square").font(.system(size: 13))
                        .foregroundStyle(item.done ? StudioColors.ok : StudioColors.muted).frame(width: 16, height: 18)
                    Text(item.text).font(.studio(12.5)).foregroundStyle(item.done ? StudioColors.muted : StudioColors.ink)
                        .strikethrough(item.done)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 22)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(item.done ? "Done" : "Open"): \(item.text)")
            }
        }
    }
}

/// Claude's verdict: the word in bold, its reasons, a rule down the left edge.
struct VerdictBlock: View {
    let verdict: ProofVerdict

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(rule).frame(width: 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(word).font(.studio(13, .bold)).foregroundStyle(StudioColors.ink)
                ForEach(Array(verdict.reasons.enumerated()), id: \.offset) { _, reason in
                    ProofNoteRow(kind: nil, text: reason, done: false)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(StudioColors.chip))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Claude's verdict: \(word). \(verdict.reasons.joined(separator: ". "))")
    }

    private var word: String {
        switch verdict.verdict {
        case .merge: "Merge"
        case .hold: "Hold"
        case .notReady: "Not ready"
        }
    }

    private var rule: Color { verdict.verdict == .merge ? StudioColors.coralInk : StudioColors.danger }
}
