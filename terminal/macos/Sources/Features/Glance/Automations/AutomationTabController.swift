import AppKit
import Combine
import GlanceCore
import GlanceKit
import SwiftUI

/// UI · Runs · Setup.
enum AutomationTabMode: String, CaseIterable {
    case ui, runs, setup

    var title: String {
        switch self {
        case .ui: "UI"
        case .runs: "Runs"
        case .setup: "Setup"
        }
    }
}

/// The automation the front automation tab shows: the side bar marks its row.
@MainActor
final class AutomationsNavigation: ObservableObject {
    static let shared = AutomationsNavigation()

    @Published var current: String?
}

/// An automation's tab (spec 2026-10-09-automations-design.md, "The UI": `GlanceTabHost` kind `automation`, key =
/// its id, one per window): the top bar (name, Run, the enabled switch, UI / Runs / Setup), the inline approvals of
/// runs started here, and the page for the mode. While it's open, its manual runs ask in the tab instead of on a card
/// (`AutomationEngine.tabOpened`).
@MainActor
final class AutomationTabController: NSWindowController, NSWindowDelegate, GlanceTabController, GlancePaneOwner,
    ObservableObject {
    static let kind = "automation"

    let id: String
    var tabKind: String { Self.kind }
    var tabKey: String { id }
    @Published var glancePaneOpen: Bool = GlanceTerminalHost.paneOpenDefault
    @Published var glancePlacement: PaneLayout.Placement?
    /// The pane follows the window's terminal, as on Home.
    var glanceDirectory: String? { HomeTabs.terminal(near: window)?.glanceDirectory }

    @Published var mode: AutomationTabMode = .ui
    /// The run Runs shows (nil: the newest).
    @Published var selectedRun: String?
    /// Run on a version that isn't approved: the inputs waiting for "Approve and run".
    @Published var pendingRun: [String: AutomationValue]?
    /// The `AutomationApproval.hash` of the manifest when the approval was asked for: "Approve and run" approves
    /// exactly that version.
    private var pendingHash: String?
    /// The generated form's text by input name, and what's wrong under each field.
    @Published var formValues: [String: String] = [:]
    @Published var formErrors: [String: String] = [:]
    /// Why the last Run didn't start; or that it's queued behind the run going.
    @Published var runProblem: String?
    @Published var runNote: String?
    /// The package has ui/index.html (the UI mode shows the web view; otherwise the generated form).
    @Published private(set) var hasUI = false

    private var web: AutomationWebHost?
    private var entriesWatch: AnyCancellable?
    /// The engine was told this tab is open and hasn't been told it closed: `tabOpened` and `tabClosed` pair up
    /// exactly, whichever way the tab goes.
    private var counted = false

    init(id: String) {
        self.id = id
        let window = GlanceTabWindow()
        super.init(window: window)
        window.delegate = self
        window.contentView = PullRequestHostingView(rootView: AutomationTabView(controller: self))
        AutomationEngine.shared.tabOpened(id)
        counted = true
        entriesChanged()
        entriesWatch = AutomationEngine.shared.$entries.dropFirst().sink { [weak self] _ in
            // After the engine's own update.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.entriesChanged() } }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Tells the engine the tab is gone (once): a manual run still waiting gets its card when it was the last tab.
    private func uncount() {
        guard counted else { return }
        counted = false
        AutomationEngine.shared.tabClosed(id)
    }

    /// Opens `id`'s tab in `parent`'s window (made when it has none; with no parent, the tab already open comes
    /// forward), on `mode`, or on Runs with `run` selected. Shows the Automations side bar.
    @discardableResult
    static func open(_ id: String, mode: AutomationTabMode? = nil, run: String? = nil,
                     from parent: NSWindow?) -> AutomationTabController? {
        guard StudioFeatures.shared.isOn(.automations) else { return nil }
        // An agent's tab shows the Agents side bar (while Agents is on), the rest the Automations one.
        let isAgent = AutomationEngine.shared.entry(id)?.manifest?.isAgent == true
        SidebarModeModel.shared.show(isAgent && StudioFeatures.shared.isOn(.agents) ? .agents : .automations)
        let controller: AutomationTabController?
        if parent == nil, let open = GlanceTabHost.controllers(kind: kind)
            .first(where: { $0.tabKey == id }) as? AutomationTabController {
            open.window?.tabGroup?.selectedWindow = open.window
            open.showWindowSafely(nil)
            NSApp.activate(ignoringOtherApps: true)
            controller = open
        } else {
            controller = GlanceTabHost.open(kind: kind, key: id, from: parent) { AutomationTabController(id: id) }
        }
        if let mode { controller?.mode = mode }
        // An agent waiting on you opens on the run that asks, where the answer is given.
        if mode == nil, run == nil,
           let asking = AutomationEngine.shared.live.first(where: { $0.ref.automation == id && $0.question != nil }) {
            controller?.selectedRun = asking.ref.run
            controller?.mode = .runs
        }
        if let run {
            controller?.selectedRun = run
            controller?.mode = .runs
        }
        return controller
    }

    /// The UI mode's web view, made the first time it shows.
    func webHost() -> AutomationWebHost {
        if let web { return web }
        let host = AutomationWebHost(id: id)
        host.onNeedsApproval = { [weak self] inputs in self?.askApproval(inputs) }
        web = host
        return host
    }

    /// Run on a version that isn't approved: the banner asks, remembering which version it showed.
    private func askApproval(_ inputs: [String: AutomationValue]) {
        pendingHash = AutomationEngine.shared.entry(id)?.manifest.map(AutomationApproval.hash)
        pendingRun = inputs
    }

    private func entriesChanged() {
        let engine = AutomationEngine.shared
        window?.title = engine.entry(id)?.name ?? id
        if engine.entry(id) == nil, pendingRun != nil || runProblem != nil || runNote != nil {
            // Deleted: nothing is left to approve, and the messages were about it.
            pendingRun = nil
            pendingHash = nil
            runProblem = nil
            runNote = nil
        }
        let page = engine.library.folder(id).appendingPathComponent(AutomationWeb.indexPath)
        let has = FileManager.default.fileExists(atPath: page.path)
        if has != hasUI { hasUI = has }
        web?.entriesChanged()
    }

    // MARK: Running

    /// Run (the top bar, the form): starts it, or asks for the approval inline, or says what's wrong (under the
    /// form's fields when it's the inputs).
    func run(_ inputs: [String: AutomationValue]) {
        let engine = AutomationEngine.shared
        guard let entry = engine.entry(id) else { return }
        runProblem = nil
        runNote = nil
        formErrors = [:]
        // The same check a run makes: nothing starts, and nothing asks for an approval, while an input is wrong.
        if let manifest = entry.manifest, entry.problems.isEmpty {
            let errors = AutomationFormModel.errors(manifest, inputs: inputs)
            if !errors.isEmpty {
                if hasUI {
                    // The page has its own fields: the first problem, with the input's name.
                    let first = manifest.inputs.compactMap { input in errors[input.name].map { (input.name, $0) } }.first
                    runProblem = first.map { "\(AutomationFormModel.label($0.0)): \($0.1)" } ?? "An input is wrong."
                } else {
                    formErrors = errors
                    mode = .ui
                }
                return
            }
        }
        if entry.problems.isEmpty, entry.manifest != nil, !entry.approval.isApproved {
            askApproval(inputs)
            return
        }
        switch engine.run(id, inputs: inputs) {
        case .started(let ref):
            selectedRun = ref.run
        case .queued(let place):
            runNote = place == 1 ? "Queued: it runs when the run going now ends."
                : "Queued: \(place - 1) other runs go before it."
        case .refused(let reason):
            runProblem = reason
        }
    }

    /// The top bar's Run: what the generated form holds when the automation has no page of its own, else no inputs.
    /// A page with required inputs owns its fields: the tab shows it instead of failing.
    func runFromBar() {
        guard let manifest = AutomationEngine.shared.entry(id)?.manifest else { return run([:]) }
        if hasUI {
            if !manifest.resolveInputs([:]).problems.isEmpty {
                runProblem = nil
                pendingRun = nil
                pendingHash = nil
                mode = .ui
                runNote = "Fill in the form to run it."
                return
            }
            return run([:])
        }
        run(AutomationFormModel.inputs(AutomationFormModel.fields(manifest), values: formValues))
    }

    /// Re-run from Runs: the old run's inputs, minus the ones this version no longer has.
    func rerun(_ inputs: [String: AutomationValue]) {
        let known = Set(AutomationEngine.shared.entry(id)?.manifest?.inputs.map(\.name) ?? [])
        run(inputs.filter { known.contains($0.key) && $0.value != .null })
    }

    /// The inline approval's "Not now".
    func dismissApproval() {
        pendingRun = nil
        pendingHash = nil
    }

    /// The inline approval's "Approve and run": approves the version the banner showed. When it changed since (a hand
    /// edit, a save), nothing is approved, the banner shows the new lines, and the user decides again.
    func approveAndRun() {
        guard let inputs = pendingRun else { return }
        let engine = AutomationEngine.shared
        guard let manifest = engine.entry(id)?.manifest, let shown = pendingHash else {
            pendingRun = nil
            pendingHash = nil
            return
        }
        switch engine.approve(id, expecting: shown) {
        case .approved:
            pendingRun = nil
            pendingHash = nil
            run(inputs)
        case .changedSinceShown:
            // The banner now shows the new lines: the next click approves those.
            pendingHash = AutomationApproval.hash(manifest)
            runProblem = "It changed while you were looking. Check the new lines."
        case .broken:
            pendingRun = nil
            pendingHash = nil
            runProblem = "It can't be approved while it has problems: see Setup."
        case .restoring:
            runProblem = "It's being restored. Try again in a moment."
        case .notSaved:
            runProblem = "Glance couldn't save the approval. Try again."
        }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        GlanceTerminalHost.shared.focusChanged(self)
        AutomationsNavigation.shared.current = id
    }

    func windowWillClose(_ notification: Notification) {
        uncount()
        if AutomationsNavigation.shared.current == id { AutomationsNavigation.shared.current = nil }
        entriesWatch = nil
        // The page's process and anything it polls stop with the tab.
        web?.tearDown()
        web = nil
        GlanceTabHost.closed(self)
        DispatchQueue.main.async { [weak window] in MainActor.assumeIsolated { window?.contentView = nil } }
    }
}

/// The automation tab: the side bar column, the page, and the Glance pane.
struct AutomationTabView: View {
    @ObservedObject var controller: AutomationTabController
    @ObservedObject private var tabSidebar = TabSidebarModel.shared

    var body: some View {
        HStack(spacing: 0) {
            if tabSidebar.isOpen {
                SidebarColumn()
            }
            HSplitView {
                AutomationPage(controller: controller)
                    .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                    .background(StudioColors.background)
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
        }
        .glancePlacement($controller.glancePlacement)
        .activityStrip()
    }
}

/// The top bar, the banners, and the mode's page; or, when the automation was deleted, a note saying so.
private struct AutomationPage: View {
    @ObservedObject var controller: AutomationTabController
    @ObservedObject private var engine = AutomationEngine.shared

    var body: some View {
        if let entry = engine.entry(controller.id) {
            VStack(spacing: 0) {
                AutomationTopBar(controller: controller, entry: entry)
                AutomationBanners(controller: controller, entry: entry)
                content(entry)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("This automation is gone")
                    .font(.studio(15, .semibold))
                    .foregroundStyle(StudioColors.ink)
                Text("\(controller.id) isn't in the library any more. If you just deleted it, Undo in the side bar "
                     + "brings it back.")
                    .font(.studio(12.5))
                    .foregroundStyle(StudioColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                StudioButton(title: "Close tab", style: .secondary) { controller.window?.performClose(nil) }
                    .padding(.top, 4)
            }
            .frame(maxWidth: 440, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder private func content(_ entry: AutomationEntry) -> some View {
        switch controller.mode {
        case .ui:
            if let manifest = entry.manifest, entry.problems.isEmpty {
                if controller.hasUI {
                    WebViewHost(view: controller.webHost().view)
                } else {
                    AutomationForm(controller: controller, manifest: manifest)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(entry.name) can't run")
                        .font(.studio(15, .semibold))
                        .foregroundStyle(StudioColors.ink)
                    ForEach(entry.problems.prefix(3), id: \.self) { InlineError(message: $0.description) }
                    StudioButton(title: "Open Setup", style: .secondary) { controller.mode = .setup }
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(32)
            }
        case .runs:
            AutomationRunsView(id: controller.id, selection: $controller.selectedRun) { controller.rerun($0) }
                .id(controller.id)
        case .setup:
            AutomationSetupView(id: controller.id)
        }
    }
}

/// Name and version, UI / Runs / Setup, the enabled switch, and Run (⌘↩) as the page's primary action. Run hides on
/// the generated form (it has its own) and steps down to secondary while a banner asks for an approval.
private struct AutomationTopBar: View {
    @ObservedObject var controller: AutomationTabController
    let entry: AutomationEntry
    @ObservedObject private var engine = AutomationEngine.shared

    var body: some View {
        let running = engine.live.contains { $0.ref.automation == entry.id }
        let asking = controller.pendingRun != nil
            || engine.live.contains { $0.ref.automation == entry.id && $0.parked }
        let formShows = controller.mode == .ui && !controller.hasUI && !entry.isBroken
        // Setup's Approve is that page's coral primary while the version isn't approved.
        let primary = !asking && !(controller.mode == .setup && !entry.approval.isApproved)
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.name)
                        .font(.studio(15, .semibold))
                        .tracking(-0.15)
                        .foregroundStyle(StudioColors.ink)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    if let version = entry.manifest?.version {
                        Text("v\(version)")
                            .font(.studioMono(11))
                            .foregroundStyle(StudioColors.muted)
                    }
                }
                if let description = entry.manifest?.description, !description.isEmpty {
                    Text(description)
                        .font(.studio(12))
                        .foregroundStyle(StudioColors.muted)
                        .lineLimit(1)
                        .help(description)
                }
            }
            Spacer(minLength: 12)
            SegmentedTabs(items: AutomationTabMode.allCases.map { SegmentItem(value: $0, title: $0.title, count: nil) },
                          selection: $controller.mode)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Text("Triggers")
                    .font(.studio(12))
                    .foregroundStyle(StudioColors.muted)
                SettingsSwitch(label: "\(entry.name) triggers on",
                               isOn: Binding(get: { entry.enabled }, set: { engine.setEnabled(entry.id, $0) }),
                               enabled: !entry.isBroken)
            }
            .help(entry.enabled ? "Its triggers fire while it's approved" : "Its triggers are off; Run still works")
            if !formShows {
                StudioButton(title: running ? "Running" : "Run", icon: .play, hint: asking ? nil : "⌘↩",
                             style: primary ? .primary : .secondary, busy: running,
                             enabled: !entry.isBroken && !asking) { controller.runFromBar() }
                    .keyboardShortcut(asking ? nil : KeyboardShortcut(.return, modifiers: .command))
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 58)
        .overlay(alignment: .bottom) { Rectangle().fill(StudioColors.line).frame(height: 1) }
    }
}

/// Under the top bar (spec "Approvals": a manual run from the tab shows its approval here instead of a card): a run
/// waiting at an outward step, Run on a version that isn't approved yet, or why a run didn't start.
private struct AutomationBanners: View {
    @ObservedObject var controller: AutomationTabController
    let entry: AutomationEntry
    @ObservedObject private var engine = AutomationEngine.shared

    var body: some View {
        VStack(spacing: 0) { banners }
    }

    @ViewBuilder private var banners: some View {
        if let parked = engine.live.first(where: { $0.ref.automation == entry.id && $0.parked }) {
            AutomationBanner {
                Text(entry.name).fontWeight(.semibold) + Text(" wants to run ")
                    + Text(parked.step ?? "a step").font(.studioMono(13, .semibold))
            } detail: {
                if let plan = engine.parkedPlan(parked.ref) {
                    AutomationTextBlock(text: plan.preview)
                }
            } actions: {
                StudioButton(title: "Skip", style: .quiet) { engine.decide(parked.ref, .skip) }
                StudioButton(title: "Trust this automation", style: .secondary) { engine.decide(parked.ref, .trust) }
                StudioButton(title: "Approve", icon: .check, hint: "⌘↩", style: .primary) {
                    engine.decide(parked.ref, .approve)
                }
                .keyboardShortcut(.return, modifiers: .command)
            }
        } else if controller.pendingRun != nil {
            AutomationBanner {
                Text("Approve ") + Text(entry.name).fontWeight(.semibold) + Text(" to run it")
            } detail: {
                AutomationLines(lines: engine.approvalLines(entry.id))
            } actions: {
                StudioButton(title: "Not now", style: .quiet) { controller.dismissApproval() }
                StudioButton(title: "Approve and run", icon: .check, hint: "⌘↩", style: .primary) {
                    controller.approveAndRun()
                }
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        if let problem = controller.runProblem {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                InlineError(message: problem)
                Button("Dismiss") { controller.runProblem = nil }
                    .buttonStyle(.plain)
                    .font(.studio(12, .medium))
                    .foregroundStyle(StudioColors.muted)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(StudioColors.line).frame(height: 1) }
        }
        if let note = controller.runNote {
            Text(note)
                .font(.studio(12))
                .foregroundStyle(StudioColors.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) { Rectangle().fill(StudioColors.line).frame(height: 1) }
        }
    }
}

/// MASTER §8's banner: full width on the note fill, the question in the note's ink, its detail, actions on the right.
private struct AutomationBanner<Title: View, Detail: View, Actions: View>: View {
    @ViewBuilder var title: Title
    @ViewBuilder var detail: Detail
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            title
                .font(.studio(13))
                .foregroundStyle(StudioColors.noteInk)
            detail
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                actions
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(StudioColors.note)
        .overlay(alignment: .bottom) { Rectangle().fill(StudioColors.line).frame(height: 1) }
    }
}
