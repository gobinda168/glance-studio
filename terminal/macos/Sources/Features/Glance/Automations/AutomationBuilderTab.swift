import AppKit
import Combine
import GlanceCore
import GlanceKit
import SwiftUI

/// What a builder tab works on; its key in `GlanceTabHost` (one tab per automation or run per window; each New
/// automation is a tab of its own).
enum AutomationBuilderTarget: Equatable {
    case new(UUID)
    /// A new agent: the builder primed for a `"kind": "agent"` package.
    case newAgent(UUID)
    case edit(String)
    case run(AutomationRunRef)

    var key: String {
        switch self {
        case .new(let token): "new:\(token.uuidString)"
        case .newAgent(let token): "new-agent:\(token.uuidString)"
        case .edit(let id): "edit:\(id)"
        case .run(let ref): "run:\(ref)"
        }
    }
}

/// The automation builder (spec 2026-10-09-automations-design.md, "Builder tab"): a Razor-Chat-style Claude session
/// in the automation library, with the Glance plugin (every `claude` Studio starts loads it) and the Glance MCP's
/// tools allowed. The first message carries the user's request and the priming (`AutomationBuilderText`); the
/// conversation is the session's transcript (`ChatFeed`). When a save lands in the library, the tab offers
/// "Open <name>", which opens the automation's tab on Setup for the approval.
@MainActor
final class AutomationBuilderTabController: NSWindowController, NSWindowDelegate, GlanceTabController, GlancePaneOwner,
    ObservableObject {
    static let kind = "automationBuilder"

    let target: AutomationBuilderTarget
    let subject: AutomationBuilderSubject
    var tabKind: String { Self.kind }
    var tabKey: String { target.key }
    @Published var glancePaneOpen: Bool = GlanceTerminalHost.paneOpenDefault
    @Published var glancePlacement: PaneLayout.Placement?
    var glanceDirectory: String? { root }

    /// The composer's text.
    @Published var draft: String
    @Published private(set) var thread = ChatThread()
    /// A turn is going (from Send until Claude's result, a stop or a failure).
    @Published private(set) var working = false
    /// Why the last turn failed (Claude Code missing included).
    @Published private(set) var problem: String?
    /// Automations this session saved, the latest last (see `reconcileSaves`).
    @Published private(set) var saved: [String] = []

    /// The library: the session's working directory.
    let root: String
    private let chats = ChatSessions(storage: .memory, extraArguments: AutomationBuilderText.claudeArguments)
    private let feed = ChatFeed()
    private var sentFirst = false
    private var versions: [String: Int]
    private var entriesWatch: AnyCancellable?
    /// Set when the window closes: a transcript poll still in flight must not follow the file after that.
    private var closed = false
    /// Library changes (ids, in order) that landed while this session was working or just after: save candidates.
    private var candidates: [String] = []
    private var lastWorked: Date?

    /// The glance CLI inside the app (the skill's `automation check`).
    static var cli: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/glance").path }

    init(target: AutomationBuilderTarget, subject: AutomationBuilderSubject, notice: String? = nil) {
        self.target = target
        self.subject = subject
        problem = notice
        root = AutomationEngine.shared.library.root.path
        draft = AutomationBuilderText.prefill(subject)
        versions = Self.versions()
        let window = GlanceTabWindow()
        super.init(window: window)
        window.delegate = self
        window.title = AutomationBuilderText.title(subject)
        window.contentView = PullRequestHostingView(rootView: AutomationBuilderTabView(controller: self))
        feed.onThread = { [weak self] thread in
            self?.thread = thread
            self?.reconcileSaves()
        }
        chats.onEvent = { [weak self] _, event in self?.chatEvent(event) }
        entriesWatch = AutomationEngine.shared.$entries.dropFirst().sink { [weak self] _ in
            // After the engine's own update.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.entriesChanged() } }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The engine's three ways in (A3 renders their buttons): New automation, Edit with Claude, and Ask Claude about
    /// a run (Runs' button and the failure card's Ask Claude to fix).
    static func installHooks() {
        let engine = AutomationEngine.shared
        engine.onNewAutomation = { open(.new(UUID()), from: SettingsTabController.frontWindow) }
        engine.onEditWithClaude = { id in open(.edit(id), from: SettingsTabController.frontWindow) }
        engine.onAskClaude = { ref in open(.run(ref), from: SettingsTabController.frontWindow) }
    }

    /// Opens (or brings forward) the builder for `target` in `parent`'s window. Nil when Automations is off, or the
    /// automation or run is gone.
    @discardableResult
    static func open(_ target: AutomationBuilderTarget, from parent: NSWindow?) -> AutomationBuilderTabController? {
        guard StudioFeatures.shared.isOn(.automations) else {
            NSSound.beep()
            return nil
        }
        guard let subject = subject(for: target) else {
            // The automation or run is gone: a tab that says so and still takes a new request.
            let notice = missing(target)
            SidebarModeModel.shared.show(.automations)
            let fresh = AutomationBuilderTarget.new(UUID())
            return GlanceTabHost.open(kind: kind, key: fresh.key, from: parent) {
                AutomationBuilderTabController(target: fresh, subject: .new, notice: notice)
            }
        }
        if case .newAgent = target { SidebarModeModel.shared.show(.agents) } else { SidebarModeModel.shared.show(.automations) }
        return GlanceTabHost.open(kind: kind, key: target.key, from: parent) {
            AutomationBuilderTabController(target: target, subject: subject)
        }
    }

    /// Why `target` has no subject.
    private static func missing(_ target: AutomationBuilderTarget) -> String {
        switch target {
        case .new, .newAgent:
            return "Nothing to open."
        case .edit:
            return "That automation is gone, so there is nothing to change. You can describe a new one here."
        case .run(let ref):
            return AutomationEngine.shared.entry(ref.automation) == nil
                ? "That run's automation is gone. You can describe a new automation here."
                : "That run is older than the history Glance has loaded. Open the automation's Runs page, "
                + "or describe a change here."
        }
    }

    static func subject(for target: AutomationBuilderTarget) -> AutomationBuilderSubject? {
        let engine = AutomationEngine.shared
        switch target {
        case .new:
            return .new
        case .newAgent:
            return .newAgent
        case .edit(let id):
            guard let entry = engine.entry(id) else { return nil }
            return .edit(id: id, name: entry.name, version: entry.manifest?.version ?? 0)
        case .run(let ref):
            guard let entry = engine.entry(ref.automation),
                  let record = engine.runs(ref.automation, limit: 200).first(where: { $0.id == ref.run }) else {
                return nil
            }
            return .run(ref, name: entry.name, summary: AutomationBuilderText.runSummary(record),
                        failed: [.failed, .expired, .interrupted].contains(record.status))
        }
    }

    /// Ids and versions of the valid automations now.
    private static func versions() -> [String: Int] {
        var versions: [String: Int] = [:]
        for entry in AutomationEngine.shared.entries {
            if let manifest = entry.manifest { versions[entry.id] = manifest.version }
        }
        return versions
    }

    // MARK: The conversation

    /// Send (⌘↩): the first message carries the priming.
    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !working else { return }
        let message = sentFirst ? text
            : AutomationBuilderText.firstMessage(text, subject: subject, library: root, cli: Self.cli)
        sentFirst = true
        draft = ""
        problem = nil
        working = true
        chats.send(message, root: root)
    }

    /// Stop (Esc): the turn ends; the next message resumes the session.
    func stop() {
        chats.stop(root: root)
    }

    private func chatEvent(_ event: ChatSessions.Event) {
        switch event {
        case .started(let sessionID):
            followTranscript(sessionID, tries: 0)
        case .finished:
            working = false
            lastWorked = Date()
        case .failed(let message):
            working = false
            lastWorked = Date()
            problem = message
        }
    }

    /// Claude Code writes the transcript once the first message is in: look for it every half second, for a minute.
    private func followTranscript(_ sessionID: String, tries: Int) {
        if closed { return }
        if let path = ChatFeed.locate(id: sessionID) {
            feed.follow(path, root: root)
            return
        }
        guard tries < 120, !closed, window != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { self?.followTranscript(sessionID, tries: tries + 1) }
        }
    }

    /// A library change counts as this session's save only if it landed while the session worked (or in the
    /// moment after) and the thread holds an `automation_save` call for it. Another tab's save, a hand edit or a
    /// broken package becoming valid has no such call here.
    private func entriesChanged() {
        let now = Self.versions()
        let fresh = AutomationBuilderText.saved(before: versions, after: now)
        versions = now
        guard !fresh.isEmpty else { return }
        if working || lastWorked.map({ Date().timeIntervalSince($0) < 3 }) == true {
            candidates += fresh
            reconcileSaves()
        }
    }

    private func reconcileSaves() {
        let calls = thread.items.filter {
            if case .tool(let name, _) = $0 { return name == AutomationMCP.toolPrefix + "automation_save" }
            return false
        }.count
        var ids: [String] = []
        for id in candidates.prefix(calls) { ids = ids.filter { $0 != id } + [id] }
        if ids != saved { saved = ids }
    }

    /// "Open <name>": the automation's tab on Setup, for the approval.
    func openSaved(_ id: String) {
        AutomationTabController.open(id, mode: .setup, from: window)
    }

    /// A link in Claude's answer: PRs, issues, Slack and files open in Studio, other pages in the browser.
    func openLink(_ url: URL) {
        AutomationLinkOpener.open(url.absoluteString, from: window)
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        GlanceTerminalHost.shared.focusChanged(self)
    }

    func windowWillClose(_ notification: Notification) {
        closed = true
        chats.stop(root: root)
        feed.follow(nil, root: nil)
        entriesWatch = nil
        GlanceTabHost.closed(self)
        DispatchQueue.main.async { [weak window] in MainActor.assumeIsolated { window?.contentView = nil } }
    }
}
