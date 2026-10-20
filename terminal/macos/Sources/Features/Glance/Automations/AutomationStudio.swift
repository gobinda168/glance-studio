import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// What Studio does for an automation from anywhere (the side bar, the tab, the cards): Claude's three ways in, which
/// stage A4 fills through the engine's hooks (`onNewAutomation`, `onEditWithClaude`, `onAskClaude`), Finder, and
/// Delete with its Undo.
@MainActor
enum AutomationStudio {
    /// The builder's buttons show before A4; until it sets the engine's hooks they're off and say why.
    static let builderMissing = "Comes with the automation builder, which isn't in this build yet."

    static var canBuild: Bool { AutomationEngine.shared.onNewAutomation != nil }
    static var canEdit: Bool { AutomationEngine.shared.onEditWithClaude != nil }
    static var canAsk: Bool { AutomationEngine.shared.onAskClaude != nil }

    static func newAutomation() { AutomationEngine.shared.onNewAutomation?() }
    /// The builder primed for a new agent (spec 2026-10-10-agents-design.md).
    static func newAgent() {
        AutomationBuilderTabController.open(.newAgent(UUID()), from: SettingsTabController.frontWindow)
    }
    static func editWithClaude(_ id: String) { AutomationEngine.shared.onEditWithClaude?(id) }
    static func askClaude(_ ref: AutomationRunRef) { AutomationEngine.shared.onAskClaude?(ref) }

    static func reveal(_ id: String) {
        NSWorkspace.shared.activateFileViewerSelecting([AutomationEngine.shared.library.folder(id)])
    }

    /// The library folder in Finder (made first if it isn't there yet).
    static func revealLibrary() {
        let root = AutomationEngine.shared.library.root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    /// What the side bar's "Deleted <name>. Undo" brings back.
    struct Undo: Equatable {
        let id: String
        let name: String
        let commit: String
    }

    /// Deletes `id` (a commit by Glance). Returns what Undo restores, or nil: the delete failed or was cancelled (an
    /// alert says why when it failed), or it can't be undone (an alert says so). The history checks run off the main
    /// thread; only the engine's own delete (it mutates its state) runs on it.
    static func delete(_ id: String) async -> Undo? {
        let engine = AutomationEngine.shared
        let library = engine.library
        let name = engine.entry(id)?.name ?? id
        // Ask first unless Undo is certain: there must be an earlier version in git's history to bring back.
        let before = await Task.detached(priority: .userInitiated) { library.history(id) }.value
        var reason: String?
        switch before {
        case .needsGit:
            reason = "Without git installed, Glance keeps no history of automations. This can't be undone."
        case .entries(let entries):
            if !entries.contains(where: { $0.version != nil }) {
                reason = "Glance has no saved version of it in its history. This can't be undone."
            }
        }
        if let reason {
            let alert = NSAlert()
            alert.messageText = "Delete \(name)?"
            alert.informativeText = reason
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        }
        switch engine.delete(id) {
        case .failure(let error):
            show("Couldn't delete \(name)", error.message)
            return nil
        case .success(let saved):
            let after = saved.commit == nil
                ? nil : await Task.detached(priority: .userInitiated) { library.history(id) }.value
            if case .entries(let entries)? = after, let target = AutomationHistoryText.undoTarget(entries) {
                return Undo(id: id, name: name, commit: target.commit)
            }
            show("\(name) was deleted", "Glance couldn't record the deletion in its history, so it can't be undone.")
            return nil
        }
    }

    /// Restores what Delete removed (a new commit; it starts unapproved).
    static func undo(_ undo: Undo) async {
        if case .failure(let error) = await AutomationEngine.shared.restore(undo.id, commit: undo.commit) {
            show("Couldn't bring back \(undo.name)", error.message)
        }
    }

    private static func show(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}

extension AutomationTriggerGlyph {
    /// The strip's line icons: a clock, a folder, the bolt (Automations' own icon) for a Glance event, an eye.
    var icon: StudioIcons.Name {
        switch self {
        case .clock: .clock
        case .folder: .folder
        case .bolt: .automations
        case .eye: .eye
        }
    }
}

/// A state as a glyph in its colour, always beside its words (colour is never the only signal): a small system
/// spinner while running, pause while waiting, a check when done, an alert when failed, a ring otherwise.
struct AutomationStatusGlyph: View {
    let tone: AutomationTone
    var size: CGFloat = 12

    var body: some View {
        Group {
            switch tone {
            case .running:
                ProgressView().controlSize(.mini).frame(width: size, height: size)
            case .waiting:
                StudioIcon(.pause, size: size, weight: 2.2).foregroundStyle(StudioColors.amber)
            case .ok:
                StudioIcon(.check, size: size, weight: 2.2).foregroundStyle(StudioColors.ok)
            case .failed:
                StudioIcon(.alert, size: size, weight: 2).foregroundStyle(StudioColors.danger)
            case .neutral:
                StudioIcon(.circle, size: size).foregroundStyle(StudioColors.muted)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Plain lines (what approving allows, what changed), each after a small dot; `code` in backticks shows as code.
struct AutomationLines: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(StudioColors.muted)
                        .frame(width: 4, height: 4)
                        .padding(.top, 7)
                    Text((try? AttributedString(markdown: line)) ?? AttributedString(line))
                        .font(.studio(12.5))
                        .foregroundStyle(StudioColors.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

/// A step's text as it printed it: JetBrains Mono on the field tint, selectable, 12 lines until "Show all", and only
/// its last 20 000 characters (the run log has everything).
struct AutomationTextBlock: View {
    let text: String
    var failed = false
    @State private var expanded = false

    var body: some View {
        let shown = AutomationRunText.tail(text)
        let lines = shown.reduce(into: 1) { count, character in if character == "\n" { count += 1 } }
        VStack(alignment: .leading, spacing: 6) {
            Text(shown)
                .font(.studioMono(12))
                .foregroundStyle(failed ? StudioColors.danger : StudioColors.body)
                .lineLimit(expanded ? nil : 12)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if lines > 12 {
                Button(expanded ? "Show less" : "Show all \(lines) lines") { expanded.toggle() }
                    .buttonStyle(.plain)
                    .font(.studio(12, .medium))
                    .foregroundStyle(StudioColors.coralInk)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.field))
    }
}
