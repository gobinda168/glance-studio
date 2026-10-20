import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The Automations side bar (spec 2026-10-09-automations-design.md, "The UI"): New automation (+, A4's builder), a
/// search field (the MCP's ranking), Needs you (waiting runs, approvals, stopped watchers, broken packages) and the
/// Library. A row: name, trigger glyphs, its last run or what it's doing, and the enabled switch; its menu: Run, Edit
/// with Claude, Reveal in Finder, History, Delete (a commit, undone from the note it leaves).
///
/// The same view serves Agents (`agents` true; spec 2026-10-10-agents-design.md, "Studio"): its library is the
/// automations whose manifest says `"kind": "agent"`, New agent opens the builder primed for one, and Needs you holds
/// only theirs. While Agents is on, the Automations side bar leaves agents out.
struct AutomationsSidebarView: View {
    let agents: Bool
    @ObservedObject private var engine = AutomationEngine.shared
    @ObservedObject private var navigation = AutomationsNavigation.shared
    @State private var window: NSWindow?
    @State private var query = ""
    @State private var undo: AutomationStudio.Undo?
    @State private var deleting: Set<String> = []
    @FocusState private var fieldFocused: Bool

    init(agents: Bool = false) { self.agents = agents }

    var body: some View {
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let own = AutomationText.only(engine.entries, agents: agents, separate: Self.separatesAgents)
        let entries = AutomationText.library(own, query: query)
        VStack(spacing: 0) {
            SidebarHeader(title: noun.capitalized + "s") {
                SidebarIconButton(icon: .plus, label: AutomationStudio.canBuild ? "New \(noun)"
                                  : "New \(noun). \(AutomationStudio.builderMissing)") {
                    if agents { AutomationStudio.newAgent() } else { AutomationStudio.newAutomation() }
                }
                .disabled(!AutomationStudio.canBuild)
                .opacity(AutomationStudio.canBuild ? 1 : 0.45)
            }
            field
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    // The way back to the full-width library (spec 2026-10-14-fullwidth-libraries-design.md).
                    LibrarySidebarRow(title: "All \(noun)s") {
                        AutomationsLibraryTabController.open(agents: agents, from: window)
                    }
                    .padding(.bottom, -14)
                    if let undo { undoNote(undo) }
                    if !searching && !needs.isEmpty { needsYou }
                    library(entries, own: own, searching: searching)
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WindowAccessor { window = $0 })
    }

    private var noun: String { agents ? "agent" : "automation" }

    /// Agents and automations have their own side bars while Agents (and so Automations) is on.
    private static var separatesAgents: Bool {
        StudioFeatures.shared.isOn(.agents) && StudioFeatures.shared.isOn(.automations)
    }

    /// The needs of this side bar's own automations.
    private var needs: [AutomationNeed] {
        let own = Set(AutomationText.only(engine.entries, agents: agents, separate: Self.separatesAgents).map(\.id))
        return engine.needs.filter { own.contains($0.automation) }
    }

    /// "Search automations": Esc clears it.
    private var field: some View {
        HStack(spacing: 8) {
            StudioIcon(.search, size: 14)
                .foregroundStyle(StudioColors.muted)
            TextField("Search \(noun)s", text: $query)
                .textFieldStyle(.plain)
                .font(.studio(12))
                .foregroundStyle(StudioColors.ink)
                .focused($fieldFocused)
                .onExitCommand { query = "" }
                .accessibilityLabel("Search \(noun)s")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(StudioColors.field))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(fieldFocused ? StudioColors.coral : StudioColors.line, lineWidth: 1))
    }

    private func sectionTitle(_ title: String) -> some View {
        Caption(title)
            .padding(.horizontal, 10)
            .padding(.top, 2)
            .padding(.bottom, 4)
    }

    private var needsYou: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionTitle("Needs you")
            ForEach(needs, id: \.rowID) { need in
                let name = engine.entry(need.automation)?.name ?? need.automation
                AutomationNeedRow(line: AutomationText.need(need, name: name)) { open(need) }
            }
        }
    }

    @ViewBuilder private func library(_ entries: [AutomationEntry], own: [AutomationEntry], searching: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if !searching { sectionTitle("Library") }
            if own.isEmpty {
                emptyLibrary
            } else if entries.isEmpty {
                Text("No \(noun) matches “\(query.trimmingCharacters(in: .whitespaces))”.")
                    .font(.studio(12))
                    .foregroundStyle(StudioColors.muted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            } else {
                ForEach(entries) { entry in
                    AutomationSidebarRow(entry: entry, live: engine.live.last { $0.ref.automation == entry.id },
                                         selected: navigation.current == entry.id, deleting: deleting.contains(entry.id),
                                         window: window) {
                        // One delete at a time per automation: the row's Delete is off until this one is done.
                        guard deleting.insert(entry.id).inserted else { return }
                        Task { @MainActor in
                            let result = await AutomationStudio.delete(entry.id)
                            deleting.remove(entry.id)
                            if result != nil { undo = result }
                        }
                    }
                }
            }
        }
    }

    private var emptyLibrary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(agents ? "No agents yet" : "No automations yet")
                .font(.studio(13, .semibold))
                .foregroundStyle(StudioColors.ink)
            Text(agents
                 ? "An agent is Claude working with your tools. It investigates, stops to ask you when it needs a "
                 + "decision, then carries on. Press + and describe what it should do."
                 : "An automation is a small tool Claude builds for you. You run it here, or it starts on a schedule, "
                 + "a file change or a Glance event.")
                .font(.studio(12))
                .foregroundStyle(StudioColors.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open the library folder") { AutomationStudio.revealLibrary() }
                .buttonStyle(.plain)
                .font(.studio(12, .medium))
                .foregroundStyle(StudioColors.coralInk)
                .padding(.top, 2)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }

    /// "Deleted Fix red CI. Undo" after a delete that git can bring back.
    private func undoNote(_ value: AutomationStudio.Undo) -> some View {
        HStack(spacing: 8) {
            Text("Deleted \(value.name).")
                .font(.studio(12))
                .foregroundStyle(StudioColors.body)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("Undo") {
                undo = nil
                Task { @MainActor in await AutomationStudio.undo(value) }
            }
            .buttonStyle(.plain)
            .font(.studio(12, .semibold))
            .foregroundStyle(StudioColors.coralInk)
            Button {
                undo = nil
            } label: {
                StudioIcon(.close, size: 12).foregroundStyle(StudioColors.muted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(StudioColors.chip))
    }

    private func open(_ need: AutomationNeed) {
        switch need {
        case .parked(let ref, _), .question(let ref, _):
            AutomationTabController.open(ref.automation, run: ref.run, from: window)
        case .approval(let id, _), .brokenWatcher(let id, _), .broken(let id, _):
            AutomationTabController.open(id, mode: .setup, from: window)
        }
    }
}

/// A Needs you row: its glyph, what's waiting, and what to do. Click opens the tab where it's done.
private struct AutomationNeedRow: View {
    let line: AutomationNeedLine
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AutomationStatusGlyph(tone: line.tone, size: 11)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.title)
                    .font(.studio(12.5, .medium))
                    .foregroundStyle(StudioColors.ink)
                    .lineLimit(1)
                if !line.detail.isEmpty {
                    Text((try? AttributedString(markdown: line.detail)) ?? AttributedString(line.detail))
                        .font(.studio(11.5))
                        .foregroundStyle(StudioColors.muted)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(hovering ? StudioColors.hover : .clear))
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .help(line.detail)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
    }
}

/// An automation in the Library: name and trigger glyphs, its status line, and its enabled switch. Click opens its
/// tab; the menu runs it, edits it with Claude, shows it in Finder, opens History, or deletes it.
private struct AutomationSidebarRow: View {
    let entry: AutomationEntry
    let live: AutomationLiveRun?
    let selected: Bool
    let deleting: Bool
    let window: NSWindow?
    let delete: () -> Void
    @ObservedObject private var engine = AutomationEngine.shared
    @State private var hovering = false

    var body: some View {
        let status = AutomationText.row(entry, live: live, now: Date())
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.studio(12.5, .medium))
                        .foregroundStyle(entry.armed ? StudioColors.ink : StudioColors.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    ForEach(AutomationText.glyphs(entry.manifest), id: \.self) { glyph in
                        StudioIcon(glyph.icon, size: 11)
                            .foregroundStyle(StudioColors.muted)
                            .accessibilityHidden(true)
                    }
                }
                HStack(spacing: 5) {
                    AutomationStatusGlyph(tone: status.tone, size: 10)
                    Text(status.text)
                        .font(.studio(11.5))
                        .foregroundStyle(status.tone == .failed ? StudioColors.danger : StudioColors.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(entry.name), \(status.text)")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default) { AutomationTabController.open(entry.id, from: window) }
            SettingsSwitch(label: "\(entry.name) on",
                           isOn: Binding(get: { entry.armed }, set: { setOn($0) }),
                           enabled: !entry.isBroken)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(selected ? StudioColors.selection : hovering ? StudioColors.hover : .clear))
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture { AutomationTabController.open(entry.id, from: window) }
        .help(entry.manifest?.description ?? entry.name)
        .contextMenu {
            Button("Run") { AutomationTabController.open(entry.id, from: window)?.run([:]) }
                .disabled(entry.isBroken)
            Button("Edit with Claude") { AutomationStudio.editWithClaude(entry.id) }
                .disabled(!AutomationStudio.canEdit)
            Button("Reveal in Finder") { AutomationStudio.reveal(entry.id) }
            Button("History") { AutomationTabController.open(entry.id, mode: .setup, from: window) }
            Divider()
            Button("Delete") { delete() }
                .disabled(deleting)
        }
        .accessibilityElement(children: .contain)
    }

    /// The switch shows whether the automation is armed (enabled, valid and approved). Turning it on for one that
    /// isn't approved opens its Setup, where the approval is given, instead of flipping a flag that arms nothing.
    private func setOn(_ on: Bool) {
        if on && !entry.approval.isApproved {
            AutomationTabController.open(entry.id, mode: .setup, from: window)
        } else {
            engine.setEnabled(entry.id, on)
        }
    }
}
