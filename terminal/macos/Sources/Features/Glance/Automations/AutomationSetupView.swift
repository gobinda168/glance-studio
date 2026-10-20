import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The automation tab's Setup (spec 2026-10-09-automations-design.md, "The UI"): whether its triggers are on and why
/// not; its problems; its permissions with Approve and what changed since the approval (A1's lines, including "Changes
/// its triggers" when the diff is otherwise empty); Trust this automation; its triggers; the versions git keeps, with
/// Restore (a new commit); its README. Edit with Claude (A4) is the page's one Claude action and its one glow.
struct AutomationSetupView: View {
    let id: String
    @ObservedObject private var engine = AutomationEngine.shared
    @State private var history: AutomationHistory?
    @State private var message: String?
    @State private var window: NSWindow?
    /// True while a restore runs, so a second click can't start another.
    @State private var restoring = false
    /// An agent's memory (state/<id>.memory.md), read when the page shows and after Forget.
    @State private var memory = ""

    var body: some View {
        if let entry = engine.entry(id) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    header(entry)
                    if let message { InlineError(message: message) }
                    if !entry.problems.isEmpty || entry.brokenWatcher != nil { problems(entry) }
                    permissions(entry)
                    triggers(entry)
                    if entry.manifest?.isAgent == true { memoryCard }
                    historyCard
                    if !entry.readme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        InsightCard(title: "README") {
                            StudioMarkdownView(markdown: entry.readme) { url in
                                AutomationLinkOpener.open(url.absoluteString, from: window)
                            }
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(WindowAccessor { window = $0 })
            .task(id: entry.manifest?.version) { await loadHistory() }
            .onAppear { memory = engine.memory(id) }
            .onChange(of: engine.live) { memory = engine.memory(id) }
        }
    }

    private func header(_ entry: AutomationEntry) -> some View {
        JournalPageHeader(title: "Setup", subtitle: AutomationSetupText.armed(entry)) {
            HStack(spacing: 8) {
                StudioButton(title: "Show in Finder", icon: .folder, style: .quiet) { AutomationStudio.reveal(id) }
                if AutomationStudio.canEdit {
                    GlowPill(title: "Edit with Claude") { AutomationStudio.editWithClaude(id) }
                } else {
                    StudioButton(title: "Edit with Claude", style: .quiet, enabled: false) {}
                        .help(AutomationStudio.builderMissing)
                }
            }
        }
    }

    /// What the agent wrote down in earlier runs, which it sees first in every Claude step; Forget clears it.
    private var memoryCard: some View {
        InsightCard(title: "Memory") {
            VStack(alignment: .leading, spacing: 10) {
                if memory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Nothing yet. When the agent decides something is worth keeping, it writes it down here and "
                         + "sees it in its next runs.")
                        .font(.studio(12.5))
                        .foregroundStyle(StudioColors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    AutomationTextBlock(text: memory)
                    StudioButton(title: "Forget everything", icon: .trash, style: .secondary) {
                        engine.clearMemory(id)
                        memory = ""
                    }
                }
            }
        }
    }

    private func problems(_ entry: AutomationEntry) -> some View {
        InsightCard(title: "Problems") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(entry.problems, id: \.self) { problem in
                    InlineError(message: problem.description)
                }
                if let stderr = entry.brokenWatcher {
                    Text("Its watcher stopped after crashing 5 times in 10 minutes. Its last words:")
                        .font(.studio(12.5))
                        .foregroundStyle(StudioColors.body)
                    AutomationTextBlock(text: stderr, failed: true)
                    StudioButton(title: "Turn on again", icon: .refresh, style: .secondary) {
                        engine.setEnabled(id, true)
                    }
                }
            }
        }
    }

    private func permissions(_ entry: AutomationEntry) -> some View {
        let changed: Bool = {
            if case .changed = entry.approval { return true }
            return false
        }()
        return InsightCard(title: "Permissions") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    StatePill(text: AutomationSetupText.approval(entry),
                              icon: entry.approval.isApproved ? .check : .alert,
                              tone: entry.approval.isApproved ? .ok : .amber)
                    Spacer(minLength: 8)
                    if !entry.approval.isApproved {
                        StudioButton(title: "Approve", icon: .check, style: .primary, enabled: !entry.isBroken) {
                            approve(entry)
                        }
                    }
                }
                Text(changed ? "What changed since you approved it"
                     : entry.approval.isApproved ? "What it may do" : "What approving lets it do")
                    .font(.studio(12.5, .semibold))
                    .foregroundStyle(StudioColors.ink)
                AutomationLines(lines: engine.approvalLines(id))
                if changed, let manifest = entry.manifest {
                    Text("Everything it may do once approved")
                        .font(.studio(12.5, .semibold))
                        .foregroundStyle(StudioColors.ink)
                    AutomationLines(lines: AutomationApproval.summary(manifest))
                }
                Rectangle().fill(StudioColors.line2).frame(height: 1)
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Trust this automation")
                            .font(.studio(13, .medium))
                            .foregroundStyle(StudioColors.ink)
                        Text("Steps marked outward (they send things outside your Mac) run without asking.")
                            .font(.studio(12))
                            .foregroundStyle(StudioColors.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    SettingsSwitch(label: "Trust this automation",
                                   isOn: Binding(get: { entry.trusted }, set: { engine.setTrusted(id, $0) }))
                }
            }
        }
    }

    private func triggers(_ entry: AutomationEntry) -> some View {
        let listed = entry.manifest?.triggers ?? []
        // Manual is always there, even when automation.json doesn't list it.
        let all = listed.contains { $0.typed == .manual } ? listed : [AutomationTrigger(kind: "manual")] + listed
        return InsightCard(title: "Triggers") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(all.enumerated()), id: \.offset) { _, trigger in
                    let line = AutomationSetupText.trigger(trigger, now: Date(), calendar: .current)
                    HStack(alignment: .top, spacing: 10) {
                        StudioIcon(line.glyph?.icon ?? .play, size: 14)
                            .foregroundStyle(StudioColors.muted)
                            .frame(width: 16)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.title)
                                .font(.studio(13, .medium))
                                .foregroundStyle(StudioColors.ink)
                            Text(line.detail)
                                .font(line.glyph == nil ? .studio(12) : .studioMono(12))
                                .foregroundStyle(StudioColors.muted)
                                .textSelection(.enabled)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var historyCard: some View {
        InsightCard(title: "History") {
            switch history {
            case .none:
                ProgressView().controlSize(.small)
            case .some(.needsGit):
                Text("\(AutomationHistory.needsGitMessage): saves still work, but there are no older versions to go "
                     + "back to.")
                    .font(.studio(12.5))
                    .foregroundStyle(StudioColors.muted)
            case .some(.entries(let entries)):
                if entries.isEmpty {
                    Text("No saved versions yet.")
                        .font(.studio(12.5))
                        .foregroundStyle(StudioColors.muted)
                } else {
                    let shown = Array(entries.prefix(30))
                    VStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.commit) { index, entry in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(AutomationHistoryText.title(entry) + (index == 0 ? " (in use)" : ""))
                                        .font(.studio(13, .medium))
                                        .foregroundStyle(StudioColors.ink)
                                    Text(AutomationHistoryText.detail(entry, now: Date()))
                                        .font(.studio(11.5))
                                        .foregroundStyle(StudioColors.muted)
                                }
                                Spacer(minLength: 8)
                                Text(entry.shortCommit)
                                    .font(.studioMono(11))
                                    .foregroundStyle(StudioColors.muted)
                                    .textSelection(.enabled)
                                if AutomationHistoryText.canRestore(entries, at: index) {
                                    StudioButton(title: "Restore", style: .secondary, enabled: !restoring,
                                                 height: 26) { restore(entry) }
                                        .accessibilityLabel("Restore \(entry.shortCommit)")
                                }
                            }
                            .padding(.vertical, 7)
                            if index < shown.count - 1 {
                                Rectangle().fill(StudioColors.line2).frame(height: 1)
                            }
                        }
                    }
                }
            }
        }
    }

    /// git runs off the main thread.
    private func loadHistory() async {
        let library = engine.library
        let automation = self.id
        history = await Task.detached { library.history(automation) }.value
    }

    /// Approves what this page showed: if the files changed since (a hand edit, a save), nothing is approved and the
    /// page shows the new lines.
    private func approve(_ entry: AutomationEntry) {
        guard let manifest = entry.manifest else { return }
        switch engine.approve(id, expecting: AutomationApproval.hash(manifest)) {
        case .approved: message = nil
        case .changedSinceShown: message = "It changed while you were looking. Check the new lines."
        case .broken: message = "Fix the problems listed here before approving."
        case .restoring: message = "It's being restored. Try again in a moment."
        case .notSaved: message = "Glance couldn't save the approval. Try again."
        }
    }

    /// A restore is a new commit (so it can be undone the same way); a changed permission or trigger needs approving.
    /// The engine does the git work off the main thread and holds the automation's runs and saves meanwhile.
    private func restore(_ entry: AutomationHistoryEntry) {
        guard !restoring else { return }
        restoring = true
        let automation = id
        let commit = entry.commit
        Task {
            // The history reloads on its own: the restored version changes the manifest's version.
            let result = await engine.restore(automation, commit: commit)
            restoring = false
            switch result {
            case .success: message = nil
            case .failure(let error): message = error.message
            }
        }
    }
}
