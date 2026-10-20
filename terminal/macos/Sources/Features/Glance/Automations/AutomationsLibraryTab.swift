import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The Automations library (or, with `agents`, the Agents one), full width with no side bar (spec
/// 2026-10-14-fullwidth-libraries-design.md): one tab per window, opened by the strip. A card opens the automation's
/// tab, where the side bar comes back. Nothing to save, so closing it never asks.
@MainActor
final class AutomationsLibraryTabController: NSWindowController, NSWindowDelegate, GlanceTabController,
    GlancePaneOwner, ObservableObject {
    static func kind(agents: Bool) -> String { agents ? "agentsLibrary" : "automationsLibrary" }

    let agents: Bool
    var tabKind: String { Self.kind(agents: agents) }
    var tabKey: String { tabKind }
    @Published var glancePaneOpen: Bool = GlanceTerminalHost.paneOpenDefault
    @Published var glancePlacement: PaneLayout.Placement?
    /// The pane follows the window's terminal, as on Home.
    var glanceDirectory: String? { HomeTabs.terminal(near: window)?.glanceDirectory }

    init(agents: Bool) {
        self.agents = agents
        let window = GlanceTabWindow()
        super.init(window: window)
        window.delegate = self
        window.title = agents ? "Agents" : "Automations"
        window.contentView = PullRequestHostingView(rootView: AutomationsLibraryTabView(controller: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Opens the library in `parent`'s window (made when it has none; with no parent, the one already open comes
    /// forward). Agents needs its feature on; both need Automations.
    @discardableResult
    static func open(agents: Bool, from parent: NSWindow?) -> AutomationsLibraryTabController? {
        guard StudioFeatures.shared.isOn(.automations), !agents || StudioFeatures.shared.isOn(.agents) else { return nil }
        let kind = kind(agents: agents)
        if parent == nil, let open = GlanceTabHost.controllers(kind: kind).first as? AutomationsLibraryTabController {
            open.window?.tabGroup?.selectedWindow = open.window
            open.showWindowSafely(nil)
            NSApp.activate(ignoringOtherApps: true)
            return open
        }
        return GlanceTabHost.open(kind: kind, key: kind, from: parent) { AutomationsLibraryTabController(agents: agents) }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        GlanceTerminalHost.shared.focusChanged(self)
    }

    func windowWillClose(_ notification: Notification) {
        GlanceTabHost.closed(self)
        DispatchQueue.main.async { [weak window] in MainActor.assumeIsolated { window?.contentView = nil } }
    }
}

/// The tab: the library and the Glance pane, without the side bar column.
struct AutomationsLibraryTabView: View {
    @ObservedObject var controller: AutomationsLibraryTabController

    var body: some View {
        HSplitView {
            AutomationsLibraryPage(agents: controller.agents)
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottomTrailing) {
                    if controller.glancePaneOpen && controller.glancePlacement == .floating {
                        GlanceFloatView()
                    }
                }
            if controller.glancePaneOpen && controller.glancePlacement == .sidebar {
                GlancePaneView()
                    .glanceSidebar()
            }
        }
        .glancePlacement($controller.glancePlacement)
        .activityStrip()
    }
}

/// The page: the header, Needs you, and the Library's cards. The same as the side bar's, with room: each card says
/// what the automation does and what starts it. Agents and automations are apart while Agents is on.
struct AutomationsLibraryPage: View {
    let agents: Bool
    @ObservedObject private var engine = AutomationEngine.shared
    @State private var window: NSWindow?
    @State private var query = ""
    @State private var filter = LibraryFilter.all
    @State private var undo: AutomationStudio.Undo?
    @State private var deleting: Set<String> = []

    var body: some View {
        let own = AutomationText.only(engine.entries, agents: agents, separate: Self.separatesAgents)
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let shown = AutomationText.library(own, query: query).filter { filter.keeps($0.armed) }
        let needs = needs(of: own)
        LibraryScroll {
            LibraryHeader(title: noun.capitalized + "s", subtitle: subtitle, searchPrompt: "Search \(noun)s",
                          query: $query, addTitle: "New \(noun)", addEnabled: AutomationStudio.canBuild,
                          addHelp: AutomationStudio.canBuild ? nil : AutomationStudio.builderMissing) {
                if agents { AutomationStudio.newAgent() } else { AutomationStudio.newAutomation() }
            }
            if let undo { undoNote(undo) }
            if !searching && !needs.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    LibraryCaption(title: "Needs you", count: needs.count)
                    ForEach(needs, id: \.rowID) { need in
                        let name = engine.entry(need.automation)?.name ?? need.automation
                        LibraryNeedRow(line: AutomationText.need(need, name: name), action: action(for: need)) { open(need) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                LibraryCaption(title: "Library", count: own.count) {
                    if !own.isEmpty {
                        LibraryFilterTabs(filter: $filter, on: own.filter(\.armed).count, off: own.filter { !$0.armed }.count)
                    }
                }
                if own.isEmpty {
                    LibraryEmpty(title: agents ? "No agents yet" : "No automations yet", text: emptyText,
                                 link: ("Open the library folder", { AutomationStudio.revealLibrary() }))
                } else if shown.isEmpty && searching {
                    LibraryNoMatch(noun: noun, query: query)
                } else if shown.isEmpty {
                    LibraryNoMatch(noun: noun, filter: filter)
                } else {
                    LibraryGrid {
                        ForEach(shown) { entry in card(entry) }
                    }
                }
            }
        }
        .background(WindowAccessor { window = $0 })
    }

    private var noun: String { agents ? "agent" : "automation" }

    private var subtitle: String {
        agents
            ? "Claude working with your tools on a trigger. An agent stops to ask you when it needs a decision, then carries on."
            : "Small tools Claude builds for you. They run from here, on a schedule, on a file change or on a Glance event."
    }

    private var emptyText: String {
        agents
            ? "An agent is Claude working with your tools. It investigates, stops to ask you when it needs a decision, "
            + "then carries on. Press New agent and describe what it should do."
            : "An automation is a small tool Claude builds for you. You run it here, or it starts on a schedule, a file "
            + "change or a Glance event. Press New automation and describe what should happen."
    }

    /// Agents and automations have their own libraries while Agents (and so Automations) is on.
    private static var separatesAgents: Bool {
        StudioFeatures.shared.isOn(.agents) && StudioFeatures.shared.isOn(.automations)
    }

    private func needs(of own: [AutomationEntry]) -> [AutomationNeed] {
        let ids = Set(own.map(\.id))
        return engine.needs.filter { ids.contains($0.automation) }
    }

    private func card(_ entry: AutomationEntry) -> some View {
        let live = engine.live.last { $0.ref.automation == entry.id }
        let status = AutomationText.row(entry, live: live, now: Date())
        return LibraryCard(name: entry.name,
                           detail: entry.manifest?.description.nonEmpty ?? entry.brokenLine ?? "No description.",
                           isOn: Binding(get: { entry.armed }, set: { setOn(entry, $0) }),
                           switchEnabled: !entry.isBroken, waiting: status.tone == .waiting && live?.parked == true,
                           open: { AutomationTabController.open(entry.id, from: window) }) {
            ForEach(Array(AutomationText.chips(entry.manifest).enumerated()), id: \.offset) { _, chip in
                LibraryChip(icon: chip.glyph.icon, text: chip.text)
            }
            Spacer(minLength: 4)
            HStack(spacing: 5) {
                AutomationStatusGlyph(tone: status.tone, size: 11)
                Text(status.text)
                    .font(.studio(11.5))
                    .foregroundStyle(status.tone == .failed ? StudioColors.danger
                                     : status.tone == .waiting ? StudioColors.amber : StudioColors.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .layoutPriority(1)
        }
        .contextMenu {
            Button("Run") { AutomationTabController.open(entry.id, from: window)?.run([:]) }
                .disabled(entry.isBroken)
            Button("Edit with Claude") { AutomationStudio.editWithClaude(entry.id) }
                .disabled(!AutomationStudio.canEdit)
            Button("Reveal in Finder") { AutomationStudio.reveal(entry.id) }
            Button("History") { AutomationTabController.open(entry.id, mode: .setup, from: window) }
            Divider()
            Button("Delete") { delete(entry.id) }
                .disabled(deleting.contains(entry.id))
        }
    }

    /// As the side bar's switch: turning on one that isn't approved opens its Setup, where the approval is given.
    private func setOn(_ entry: AutomationEntry, _ on: Bool) {
        if on && !entry.approval.isApproved {
            AutomationTabController.open(entry.id, mode: .setup, from: window)
        } else {
            engine.setEnabled(entry.id, on)
        }
    }

    private func delete(_ id: String) {
        guard deleting.insert(id).inserted else { return }
        Task { @MainActor in
            let result = await AutomationStudio.delete(id)
            deleting.remove(id)
            if result != nil { undo = result }
        }
    }

    private func action(for need: AutomationNeed) -> String {
        switch need {
        case .question: "Answer"
        case .approval: "Review"
        default: "Open"
        }
    }

    private func open(_ need: AutomationNeed) {
        switch need {
        case .parked(let ref, _), .question(let ref, _):
            AutomationTabController.open(ref.automation, run: ref.run, from: window)
        case .approval(let id, _), .brokenWatcher(let id, _), .broken(let id, _):
            AutomationTabController.open(id, mode: .setup, from: window)
        }
    }

    /// "Deleted Fix red CI. Undo" after a delete that git can bring back.
    private func undoNote(_ value: AutomationStudio.Undo) -> some View {
        HStack(spacing: 10) {
            Text("Deleted \(value.name).")
                .font(.studio(12.5))
                .foregroundStyle(StudioColors.body)
            StudioButton(title: "Undo", height: 26) {
                undo = nil
                Task { @MainActor in await AutomationStudio.undo(value) }
            }
            Spacer(minLength: 0)
            Button { undo = nil } label: {
                StudioIcon(.close, size: 12).foregroundStyle(StudioColors.muted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: 520)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StudioColors.chip))
    }
}

extension AutomationNeed {
    /// What makes a Needs you row the same row across refreshes: the automation, the kind, and the run.
    var rowID: String {
        switch self {
        case .parked(let ref, _): "parked:\(ref.automation):\(ref.run)"
        case .question(let ref, _): "question:\(ref.automation):\(ref.run)"
        case .approval(let id, _): "approval:\(id)"
        case .brokenWatcher(let id, _): "watcher:\(id)"
        case .broken(let id, _): "broken:\(id)"
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
