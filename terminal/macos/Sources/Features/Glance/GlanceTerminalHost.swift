import AppKit
import Combine
import GhosttyKit
import GlanceCore
import GlanceKit
import GlanceOverlay
import SwiftUI

/// Glance inside the terminal: one Glance session for the app, fed by watching Claude Code's transcripts (no hooks).
/// The pane in the key window shows it, and it follows the focused split's working directory: only that folder's
/// session thinks and speaks.
@MainActor
final class GlanceTerminalHost: NSObject {
    static let shared = GlanceTerminalHost()

    private static let defaults = UserDefaults(suiteName: "dev.glance.Glance") ?? .standard

    /// Whether new windows open with the pane: the last state chosen.
    static var paneOpenDefault: Bool {
        get { defaults.object(forKey: "terminalPaneOpen") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "terminalPaneOpen") }
    }

    private var session: GlanceSession?
    /// Glance's panel or the overlay's is reading a reply aloud.
    var isNarrating: Bool {
        [session, overlay?.session].contains { $0?.isSpeaking == true && $0?.isPaused == false }
    }
    /// The overlay on other terminals: running while Settings' "Overlay" switch is on.
    private(set) var overlay: OverlayController?
    /// Claude Code's hook events (for the overlay) and glance-replies' previews, on 127.0.0.1 whatever the surfaces.
    private let events = EventServer()
    private let stub = StatusStub()
    private var didLaunch = false
    private let watcher = TranscriptWatcher()
    private let dictation = DictationController()
    private let sink = SurfaceTextSink()
    private var router = SessionRouter()
    /// Which Claude session runs in which terminal (mods/glance-session's SessionStart hook).
    private let sessionLinks = SessionLinkFolder()
    /// What a relaunch types into `view`'s restored terminal: the resume of the Claude Code session it was running
    /// when the app quit, or nil (any other command stays gone).
    func resumeCommand(for view: Ghostty.SurfaceView) -> String? {
        ClaudeResume.command(running: ShellAssist.shared.paneSnapshot(for: view)?.running,
                             sessionID: router.link(for: view.id)?.sessionID)
    }

    /// The session whose summary the pane shows (spec 2026-10-11-humanize-summaries-design.md), or nil.
    private var summaryShown: SessionLink?
    /// The edits of Claude's latest edit turn, anywhere. Editors show the ones inside their project.
    private var claudeEdits: [FileEdit] = []
    /// Every file Claude edited in the latest session (absolute), for the editors' Changes views.
    private var claudeEditedPaths: [String] = []
    /// A `tell` is going onto the panel (its reply event isn't a new reply's).
    private var showingTell = false
    private weak var keyController: GlancePaneOwner?
    private var slots: [Weak<GlancePaneSlot>] = []
    // The editor chat (Razor Code tabs): Glance's headless sessions, the transcript shown, and how sends route.
    private let chats = ChatSessions()
    private let chatFeed = ChatFeed()
    /// The project of the Razor Code tab in front, or nil (no composer).
    private var chatRoot: String?
    /// A message went to a terminal's Claude in this folder: its next prompt names the transcript to follow.
    private var awaitingTerminalPrompt: String?
    private var chatNotice: String?
    /// The picker's list for `chatRoot`, read when it could have changed (not on every composer update).
    private var chatEntries: [ChatSessionEntry] = []

    /// The focused split's terminal, for dictation.
    var focusedSurfaceHandle: ghostty_surface_t? { (keyController as? BaseTerminalController)?.focusedSurface?.surface }

    func start() {
        // DM Sans and JetBrains Mono, the faces of Home, the side bars and the PR pages, before any window draws.
        GlanceFont.register(fontsDirectory: Resources.web.appendingPathComponent("vendor/fonts"))
        // The terminal suggestions' bridge, before the first window's shell starts.
        ShellAssist.shared.start()
        startEventServer()
        // Ask Claude's panel opens a note in the To-dos & Notes tab.
        CaptureStore.shared.onOpenNote = { id in _ = CapturesTabController.open(.notes(id), from: NSApp.keyWindow) }
        // A note opened in the quick note box edits with the Notes page's editor: Markdown and checkboxes.
        QuickNotePanel.shared.noteEditor = { text in
            AnyView(LiveMarkdownEditor(placeholder: "Write, paste or think out loud. Markdown works.", text: text,
                                       minHeight: 120, background: .clear, preview: true) { NSWorkspace.shared.open($0) })
        }
        let session = GlanceSession(webDirectory: Resources.web)
        self.session = session
        session.isPanelVisible = { [weak self] in self?.isPaneShowing ?? false }
        // A closed Glance stays closed until it's opened again (the top bar's Glance button, ⌥Space).
        session.onReply = { [weak self] reply, _ in
            guard let self else { return }
            self.dictation.latestReply = reply
            // A reply took the place of a `tell` on the card: it fits the reply, and doesn't fold.
            if !self.showingTell { GlanceLayoutModel.shared.endTell() }
        }
        // The floating card's ✕ (in its hover strip) folds it back into the orb below it, like ⌥Space.
        session.onCloseRequested = { [weak self] in
            guard let self else { return }
            if self.isFloating { GlanceLayoutModel.shared.cardOpen = false } else { self.setPaneOpen(false) }
        }
        session.onShowRequested = { [weak self] in self?.setPaneOpen(true) }
        // The pin in the panel's header, and the floating orb.
        let layout = GlanceLayoutModel.shared
        session.showLayout(layout.mode)
        session.onLayoutCycle = { [weak session] in
            layout.mode = layout.mode.next
            session?.showLayout(layout.mode)
        }
        session.isLevelListenerVisible = { [weak self] in self?.isFloating ?? false }
        session.onLevel = { level in layout.level(level) }
        session.onStatus = { status in layout.setStatus(status) }
        // The floating card fits its content, and a short `tell` folds back once it's been read.
        session.onContentHeight = { height in layout.contentHeight = height }
        session.onReplyRead = { layout.replyRead() }
        // File names in the pane's replies open in the project's editor tab.
        session.onOpenFile = { [weak self] text in
            guard let self, let window = self.keyController?.window else { return }
            _ = GlanceEditorHost.openFromPane(text, from: window, directory: self.keyController?.glanceDirectory)
        }
        session.onChatSend = { [weak self] text, withContext in self?.chatSend(text, withContext: withContext) }
        session.onChatStop = { [weak self] in self?.chatStop() }
        session.onChatNew = { [weak self] in self?.chatNew() }
        session.onChatOpen = { [weak self] in self?.chatOpen() }
        session.onChatSwitch = { [weak self] id in self?.chatSwitch(id) }
        chatFeed.onThread = { [weak self] thread in self?.session?.chatThread(thread) }
        chats.onEvent = { [weak self] root, event in self?.chatEvent(root, event) }

        watcher.onEvent = { [weak self] event in self?.handle(event) }
        // Claude needs you: tool calls starting and settling, for the splits whose dialogs wait on the user.
        watcher.onTool = { NeedsYouStudio.shared.tool($0) }
        if !watcher.start() { NSLog("Glance Studio: can't watch ~/.claude/projects") }
        sessionLinks.onChange = { [weak self] links in self?.linksChanged(links) }
        sessionLinks.start()
        startSummaries()

        // One dictation for the app: into the focused split while Studio is in front, typed into the app in front
        // otherwise (the overlay's way), by the switches.
        dictation.sink = RoutingTextSink(studio: sink)
        dictation.shouldStart = {
            Prefs.surfaces.dictationRoute(appActive: NSApp.isActive, studioHasFocusedTerminal: true) != .none
        }
        dictation.anchorFrame = { [weak self] in
            NSApp.isActive ? self?.keyController?.window?.frame : self?.overlay?.dictationAnchor
        }
        dictation.onHoldChanged = { [weak self] holding in
            guard let self else { return }
            if NSApp.isActive && Prefs.surfaces.terminal { self.session?.dictationHold(holding) }
            else { self.overlay?.session?.dictationHold(holding) }
        }
        // Orb channel: fn answers the active card (or talks to the orb assistant) instead of dictating.
        dictation.divert = { OrbChannelHub.shared.voiceDivert() }
        // The fn monitor also runs while the orb channel is on, without dictating when dictation is off (`shouldStart`
        // is only asked when no divert took the hold).
        let routeAllowed = dictation.shouldStart
        dictation.shouldStart = { Prefs.dictationEnabled && routeAllowed() }
        session.settings.onDictationToggle = { [weak self] _ in self?.refreshFnMonitor() }
        refreshFnMonitor()

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowBecameKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appBecameActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        // The Home entries of the tab sidebar and the top bar.
        NotificationCenter.default.addObserver(
            self, selector: #selector(showHomeRequested(_:)), name: .init("dev.glance.Terminal.showHome"), object: nil)
        installMenu()
        stub.showSettings = { [weak self] in self?.showSettings() }
        // The pane's Settings link and a cloud voice picked there without its key open the Settings tab.
        session.onShowSettings = { [weak self] section in self?.showSettings(section) }
        session.settings.onSurfacesToggle = { [weak self] in self?.surfacesToggled() }
        applySurfaces()
        // Meeting nudges: a glowing pill at the top when a meeting starts; one said out loud stops a reply being read.
        MeetingNudger.shared.willSpeak = { [weak self] in
            self?.session?.stop()
            self?.overlay?.session?.stop()
        }
        MeetingNudger.shared.start()
        // Journal: collects the day and drafts its recap; the "Your day is ready" nudge's Review opens that day.
        JournalService.shared.onReview = { day in
            JournalTabController.open(.day(day), from: SettingsTabController.frontWindow)
        }
        if StudioFeatures.shared.isOn(.journal) { JournalService.shared.start() }
        // Usage: reads Claude Code's transcripts into usage.sqlite every 2 minutes.
        if StudioFeatures.shared.isOn(.usage) { UsageService.shared.start() }
        // Notifications: meetings, terminal alerts and finished Claude turns post to the inbox; cards nudge.
        if StudioFeatures.shared.isOn(.notifications) { startNotifications() }
        // Orb channel: Claude sessions reach the user through cards, the orb and voice (glance mcp → orb.sock).
        OrbChannelStudio.start()
        // Claude needs you: a Claude dialog waiting in a split lights the orbs and gets a card.
        NeedsYouStudio.shared.start()
        // Quick note: ⌃⌥N from any app jots a note into To-dos & Notes.
        QuickNotePanel.shared.registerHotKey()
        // Tickets: the user's tickets through Claude's tracker connectors, ranked each morning; the morning card's
        // See all opens the page.
        TicketsCard.shared.onSeeAll = { TicketsTabController.open(from: SettingsTabController.frontWindow) }
        TicketsCard.shared.onOpen = { TicketRouter.open($0) }
        TicketsCard.shared.onStart = { TicketService.shared.start($0) }
        TicketsCard.shared.onMove = { TicketService.shared.move($0, to: $1, reason: "Check-in", auto: false) }
        TicketsCard.shared.onWorkOn = { TicketRouter.workOn($0, near: SettingsTabController.frontWindow) }
        TicketService.shared.onShowTicket = { id in
            TicketsNavigation.shared.selection = id
            TicketsTabController.open(from: SettingsTabController.frontWindow)
        }
        if StudioFeatures.shared.isOn(.tickets) { startTickets() }
        // Automations: the engine (library, runs, triggers), its cards' buttons, meeting.ended's publisher.
        if StudioFeatures.shared.isOn(.automations) { startAutomations() }
        // Meeting notes: a meeting left recording by a quit becomes "interrupted"; the nudge offers Record.
        MeetingRecorder.shared.recover()
        MeetingNudger.shared.onRecord = { title, eventID in
            MeetingsTabController.record(title: title, eventID: eventID, from: SettingsTabController.frontWindow)
        }
        MeetingNudger.shared.isRecording = { eventID in
            MeetingRecorder.shared.isRecording && MeetingRecorder.shared.record?.eventID == eventID
        }
        MeetingNudger.shared.openInBrowser = { link, _ in
            BrowserTabController.open(url: link.webURL, from: SettingsTabController.frontWindow) != nil
        }
        MeetingNudger.shared.offersRecording = StudioFeatures.shared.isOn(.meetingNotes)
        // A call Glance didn't start (Zoom, Teams, Slack, a browser) gets a Record pill.
        CallNudger.shared.onRecord = { title, eventID in
            MeetingsTabController.record(title: title, eventID: eventID, from: SettingsTabController.frontWindow)
        }
        CallNudger.shared.isRecording = { MeetingRecorder.shared.isBusy }
        if StudioFeatures.shared.isOn(.meetingNotes) && Prefs.meetingOfferCalls { CallNudger.shared.start() }
    }

    private var notificationsStarted = false
    private var slackReplyWatch: AnyCancellable?

    /// fn is watched while dictation or the orb channel wants it (Settings → Dictation, Settings → Orb Channel).
    func refreshFnMonitor() {
        // The notification reply card takes fn too (dictate a reply), so it keeps the monitor on with Notifications.
        let fnWanted = Prefs.dictationEnabled || (StudioFeatures.shared.isOn(.orbChannel) && Prefs.orbChannelEnabled)
            || StudioFeatures.shared.isOn(.notifications)
        dictation.setEnabled(fnWanted)
    }

    /// Tickets: its service, and its notices' buttons through the hub (whose cards show even with Notifications off).
    func startTickets() {
        let hub = NotificationHub.shared
        hub.start()
        if hub.onNudge == nil { hub.onNudge = { NudgeStack.shared.show($0) } }
        if hub.onOpen == nil { hub.onOpen = { NoticeRouter.open($0) } }
        let previous = hub.onAction
        hub.onAction = { notice, id in
            if notice.source == .tickets { TicketService.shared.handle(notice, actionID: id) } else { previous?(notice, id) }
        }
        AtlassianSessions.shared.start()
        if TicketService.shared.direct == nil { TicketService.shared.direct = JiraDirectTickets.shared }
        TicketService.shared.start()
    }

    private var automationsStarted = false
    private var automationSocket: AutomationSocketServer?

    /// Automations: the engine and its cards' buttons through the hub (whose cards show even with Notifications
    /// off). Open run opens the automation's tab on Runs; Ask Claude to fix, Ask Claude
    /// about this run, Edit with Claude and New automation open the builder tab.
    func startAutomations() {
        if !automationsStarted {
            automationsStarted = true
            let hub = NotificationHub.shared
            hub.start()
            if hub.onNudge == nil { hub.onNudge = { NudgeStack.shared.show($0) } }
            if hub.onOpen == nil { hub.onOpen = { NoticeRouter.open($0) } }
            let previous = hub.onAction
            hub.onAction = { notice, id in
                if notice.source == .automations {
                    AutomationEngine.shared.handle(notice, actionID: id)
                } else {
                    previous?(notice, id)
                }
            }
            AutomationEngine.shared.onOpenRun = { ref in
                AutomationTabController.open(ref.automation, run: ref.run, from: SettingsTabController.frontWindow)
            }
            AutomationEventPublishers.shared.start()
            AutomationBuilderTabController.installHooks()
        }
        AutomationEngine.shared.start()
        startAutomationSocket()
    }

    /// The Glance MCP's way to the engine (`glance automation mcp` → automations.sock), while Automations is on. It
    /// also puts the Glance plugin on this process's environment, for Claude processes started from now on (when
    /// Automations was switched on after launch).
    private func startAutomationSocket() {
        ClaudePluginDir.export(cli: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/glance").path)
        guard automationSocket == nil else { return }
        let path = AutomationSocketWire.path(environment: [:], home: NSHomeDirectory())
        let server = AutomationSocketServer(engine: AutomationEngine.shared, path: path)
        if let problem = server.start() {
            NSLog("Glance Studio: the automations socket didn't start: \(problem)")
            return
        }
        automationSocket = server
    }

    /// Automations switched off (Develop menu): the engine stops and the socket closes.
    func stopAutomations() {
        AutomationEngine.shared.stop()
        closeAutomationSocket()
    }

    /// The socket closes and its file goes (also at quit, so no stale file is left for the next launch to find).
    func closeAutomationSocket() {
        automationSocket?.stop()
        automationSocket = nil
    }

    /// The Notifications inbox's sources and its Open routing. At launch with the feature on, or when the Develop
    /// menu switches it on (`StudioFeatures.set`). Only once; switched off, the sources stop posting.
    func startNotifications() {
        MeetingNudger.shared.postsNotices = true
        guard !notificationsStarted else { return }
        notificationsStarted = true
        let hub = NotificationHub.shared
        hub.start()
        hub.isInMeeting = { MeetingNudger.shared.isInMeeting }
        hub.onNudge = { NudgeStack.shared.show($0) }
        hub.onOpen = { NoticeRouter.open($0) }
        // Reply: the quick-reply panel, for GitHub PR and issue notices and for Slack messages. A Slack reply is written
        // (typed, dictated, changed with Claude) either way; Send needs Claude Code's Slack connector, which the panel
        // checks when it opens (the probe runs once; Settings' Check again re-runs it).
        hub.onReply = { QuickReplyPanel.shared.show($0) }
        hub.canReply = { notice in
            switch notice.source {
            case .github: notice.kind != .githubCIFailed && notice.target != .none
            case .slack: true
            default: false
            }
        }
        if StudioFeatures.shared.isOn(.browser) {
            SlackMCPProbe.shared.check()
            startAgentBrowser()
        }
        // Rows and cards drawn before the probe answered get their Reply once it does.
        slackReplyWatch = SlackMCPProbe.shared.$status.dropFirst().sink { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { NotificationHub.shared.repliesChanged() } }
        }
        QuickReplyPanel.shared.onOpen = { NotificationHub.shared.open($0) }
        // A thread read, opened or done anywhere drops its card.
        hub.onThreadSettled = { NudgeStack.shared.dismiss(threadKey: $0.threadKey) }
        TerminalNoticeTap.shared.start()
        // GitHub notifications; it adds its read-sync on top of onThreadSettled above, so it starts after it.
        GitHubNoticeSource.shared.isEnabled = { StudioFeatures.shared.isOn(.notifications) }
        GitHubNoticeSource.shared.start()
        // The nudge stack's "+N more" opens the page.
        NotificationCenter.default.addObserver(forName: NudgeStack.showNotifications, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                NSApp.activate(ignoringOtherApps: true)
                NotificationsMenu.shared.show()
            }
        }
    }

    // MARK: The overlay

    /// The Settings switch changed. Turning the terminal off closes its windows first (unsaved editor tabs ask); a
    /// Cancel anywhere puts the switch back.
    private func surfacesToggled() {
        guard !Prefs.surfaces.terminal, TerminalWindowCloser.hasOpenWindows else { return applySurfaces() }
        let alert = NSAlert()
        alert.messageText = "Turn off the built-in terminal?"
        alert.informativeText = "Its windows close and Glance moves to the menu bar. Commands running in them end."
        alert.addButton(withTitle: "Turn Off")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return revertTerminalOff() }
        TerminalWindowCloser.closeAll { [weak self] closed in
            if closed { self?.applySurfaces() } else { self?.revertTerminalOff() }
        }
    }

    private func revertTerminalOff() {
        var stored = Prefs.surfaces
        stored.terminal = true
        Prefs.surfaces = stored
        session?.settings.refresh()
        applySurfaces()
    }

    /// Makes the app match Settings' switches: the Dock icon and a window for the terminal, the overlay running or
    /// not, and a bare menu-bar item when both are off.
    func applySurfaces() {
        let surfaces = Prefs.surfaces
        (NSApp.delegate as? AppDelegate)?.syncActivationPolicy()
        if surfaces.overlay {
            let overlay = self.overlay ?? makeOverlay()
            self.overlay = overlay
            overlay.start()
            session?.settings.onEditorsToggle = { [weak overlay] _ in overlay?.editorsSettingChanged() }
            session?.settings.onTerminalsToggle = { [weak overlay] _ in overlay?.terminalsSettingChanged() }
        } else {
            overlay?.stop()
        }
        // At launch the app delegate opens the first window itself; later, the switch coming on does.
        if surfaces.terminal, didLaunch, !TerminalWindowCloser.hasOpenWindows {
            (NSApp.delegate as? AppDelegate)?.newWindow(nil)
        }
        if !surfaces.terminal && !surfaces.overlay { stub.show() } else { stub.hide() }
        didLaunch = true
    }

    private func makeOverlay() -> OverlayController {
        OverlayController(host: .init(
            showSettings: { [weak self] section in self?.showSettings(section) },
            checkForUpdates: { (NSApp.delegate as? AppDelegate)?.checkForUpdates(nil) },
            updateItem: { UpdateMenu.item(for: .idle, canCheck: true) },
            isStudioFront: { NSApp.isActive && Prefs.surfaces.terminal },
            toggleStudioPane: { [weak self] in self?.togglePane() },
            playPauseStudio: { [weak self] in self?.playPause() },
            ownsFolder: { [weak self] cwd in self?.studioOwns(cwd) ?? false },
            treatsOwnAppAsFront: { Prefs.surfaces.treatsOwnAppAsFront },
            onReply: { [weak self] in self?.dictation.latestReply = $0 },
            onCwd: { [weak self] in self?.dictation.latestCwd = $0 }))
    }

    /// Runs for as long as Studio does: previews must work with the overlay switched off.
    private func startEventServer() {
        events.onEvent = { [weak self] event in self?.overlay?.receive(event) }
        events.onPreview = { QuickLookPreview.shared.show($0) }
        let onFailure = { (error: Error) in
            // An old Glance.app (or a second copy) holds the hook port: stay up, just without hook events.
            NSLog("Glance Studio: can't listen for Claude Code events (\(error)). Is Glance.app running?")
        }
        events.onFailure = onFailure
        let port = ProcessInfo.processInfo.environment["GLANCE_PORT"].flatMap(UInt16.init) ?? EventServer.defaultPort
        do { try events.start(port: port) } catch { onFailure(error) }
    }

    /// Whether a Studio terminal split is in this folder (or one holds the other): its Claude belongs to Studio's pane.
    private func studioOwns(_ cwd: String) -> Bool {
        guard Prefs.surfaces.terminal else { return false }
        let folders = TerminalController.all.flatMap { $0.surfaceTree.compactMap { $0.pwd } }
        return FolderOwnership.isOwned(cwd, by: folders)
    }

    /// The pane is on screen in the window in front, and this app is in front: replies may be read aloud. A closed
    /// floating card counts: the orb is there, and the card stays in the window.
    private var isPaneShowing: Bool {
        NSApp.isActive && keyController?.glancePaneOpen == true && session?.view.window != nil
    }

    // MARK: Claude sessions

    private func handle(_ event: TranscriptWatcher.Event) {
        NeedsYouStudio.shared.transcript(event)
        chatTranscriptEvent(event)
        FixJobs.shared.transcript(event)
        if event.kind == .done { claudeTurnFinished(file: event.file) }
        // A finished turn in a folder the user isn't looking at goes to the Notifications inbox.
        if event.kind == .done, StudioFeatures.shared.isOn(.notifications), let cwd = event.cwd,
           !(NSApp.isActive && router.focusedPwd == cwd) {
            NotificationHub.shared.post(TerminalNotices.finished(cwd: cwd, at: Date()))
        }
        // Tickets: a turn that names a ticket (in its prompts or its branch) is a session signal.
        if event.kind == .done, StudioFeatures.shared.isOn(.tickets) {
            TicketService.shared.sessionEnded(file: event.file, cwd: event.cwd)
        }
        // The tab sidebar's Claude status: a turn that ends in the folder being looked at is already seen.
        TabSidebarModel.shared.claudeTurn(event.kind, cwd: event.cwd, focusedFolder: NSApp.isActive ? router.focusedPwd : nil)
        apply(router.turn(event.kind, cwd: event.cwd, file: event.file))
        // Always: a finished turn in a terminal's own session schedules its summary update.
        if event.kind == .done, StudioFeatures.shared.isOn(.summaries),
           let surface = router.surface(forTranscript: event.file), let link = router.link(for: surface) {
            SummaryService.shared.turnFinished(link)
        }
    }

    /// The session-links folder changed: keep the links of terminals that are still open, then let the router redo the
    /// focused terminal's pane if its session changed (a `/clear`, a new `claude`).
    private func linksChanged(_ links: [SessionLink]) {
        let open = Set(TerminalController.all.flatMap { $0.surfaceTree.map(\.id) })
        var bySurface: [UUID: SessionLink] = [:]
        for link in links where open.contains(link.surface) { bySurface[link.surface] = link }
        for link in links where !open.contains(link.surface) { sessionLinks.remove(surface: link.surface) }
        apply(router.setLinks(bySurface))
        summaryFocusChanged()
    }

    private func apply(_ action: SessionRouter.Action) {
        guard let session else { return }
        switch action {
        case .none:
            break
        case .thinking(let cwd):
            session.setProject(cwd: cwd)
            session.thinking()
        case .show(let file, let cwd, let narrate):
            session.setProject(cwd: cwd)
            Task { await session.loadReply(from: file, narrate: narrate) }
        case .clear:
            // A terminal with no Claude session says so on the idle stage.
            let noSession = router.focusedSurface.map { router.link(for: $0) == nil } ?? false
            session.emptyKind(noSession ? "terminal" : "default")
            session.clear()
        }
    }

    // MARK: Summaries (spec 2026-10-11-humanize-summaries-design.md)

    private func startSummaries() {
        SummaryService.shared.onChange = { [weak self] id in
            guard let self, let link = self.summaryShown, link.sessionID == id else { return }
            self.pushSummary(link)
        }
        session?.onSummary = { [weak self] action, id in self?.summaryAction(action, id: id) }
    }

    /// The focused terminal's session (nil for editors and pages).
    private var focusedLink: SessionLink? { router.focusedSurface.flatMap { router.link(for: $0) } }

    private func summaryAction(_ action: String, id: String?) {
        guard StudioFeatures.shared.isOn(.summaries) else { return }
        switch action {
        case "open":
            guard let link = focusedLink else { return }
            showSummary(link)
        case "pick":
            guard let id, let link = projectSessions().first(where: { $0.link.sessionID == id })?.link else { return }
            showSummary(link)
        case "generate":
            guard let link = summaryShown else { return }
            SummaryService.shared.request(link, trigger: .userAsked)
        case "sessions":
            session?.summarySessions(projectSessions().map { entry in
                ["id": entry.link.sessionID, "title": entry.title, "turns": entry.turns,
                 "updated": entry.updated.timeIntervalSince1970, "live": entry.live] as [String: Any]
            })
        case "close":
            summaryShown = nil
            GlanceLayoutModel.shared.reading = false
        default:
            break
        }
    }

    private func showSummary(_ link: SessionLink) {
        summaryShown = link
        // Reading docks the pane on the right (the orb's card folds into it); closing puts it back.
        GlanceLayoutModel.shared.cardOpen = false
        GlanceLayoutModel.shared.reading = true
        pushSummary(link)
        SummaryService.shared.request(link, trigger: .opened)
    }

    private func pushSummary(_ link: SessionLink) {
        let mode = Prefs.summaryMode, now = Date()
        let payload: [String: Any]
        switch SummaryService.shared.state(for: link) {
        case .none:
            payload = SummaryPayload.make(kind: .none, record: nil, stale: false, message: nil, mode: mode, now: now)
        case .working(let record):
            payload = SummaryPayload.make(kind: .working, record: record, stale: false, message: nil, mode: mode, now: now)
        case .ready(let record, let stale):
            payload = SummaryPayload.make(kind: .ready, record: record, stale: stale, message: nil, mode: mode, now: now)
        case .failed(let message, let record):
            payload = SummaryPayload.make(kind: .failed, record: record, stale: false, message: message, mode: mode, now: now)
        }
        var titled = payload
        if titled["title"] as? String == "This session", let title = Self.sessionTitle(link.transcriptPath) {
            titled["title"] = title
        }
        session?.summary(titled)
    }

    /// The pane's Summary button follows the terminal in front; a summary of another session closes.
    private func summaryFocusChanged() {
        let on = StudioFeatures.shared.isOn(.summaries) && focusedLink != nil
        session?.summaryAvailable(on)
        if let shown = summaryShown, keyController is BaseTerminalController, shown.sessionID != focusedLink?.sessionID {
            summaryShown = nil
            GlanceLayoutModel.shared.reading = false
            session?.summary(["state": "closed"])
        }
    }

    /// The ☰ menu's Terminal sessions for the project in front: the open terminals' sessions, then saved summaries.
    private func projectSessions() -> [(link: SessionLink, title: String, turns: Int, updated: Date, live: Bool)] {
        guard let root = keyController?.glanceDirectory else { return [] }
        let home = NSHomeDirectory()
        let folder = SessionMatch.normalize(root, home: home)
        let inProject = { (cwd: String?) in cwd.map { SessionMatch.normalize($0, home: home) == folder } ?? false }
        var result: [(link: SessionLink, title: String, turns: Int, updated: Date, live: Bool)] = []
        var seen: Set<String> = []
        let open = Set(TerminalController.all.flatMap { $0.surfaceTree.map(\.id) })
        for surface in open {
            guard let link = router.link(for: surface), inProject(link.cwd), seen.insert(link.sessionID).inserted else { continue }
            let record = SummaryStore.load(link.sessionID)
            result.append((link, record?.title ?? Self.sessionTitle(link.transcriptPath) ?? "Terminal session",
                           record?.coveredTurns ?? 0, record?.updatedAt ?? Date(), true))
        }
        for record in SummaryStore.records(cwd: root) where seen.insert(record.sessionID).inserted {
            let link = SessionLink(surface: UUID(), sessionID: record.sessionID, transcriptPath: record.transcriptPath,
                                   cwd: record.cwd, source: nil)
            result.append((link, record.title ?? "Untitled session", record.coveredTurns, record.updatedAt, false))
        }
        return result
    }

    /// A session's first prompt, read from the head of its transcript.
    private static func sessionTitle(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 64 * 1024)) ?? nil
        return head.flatMap { ChatTranscript.title(jsonl: String(decoding: $0, as: UTF8.self), limit: 60) }
    }

    // MARK: Claude's changes

    /// Claude finished a turn: read its transcript off the main thread, take the latest edit turn, and show it.
    private func claudeTurnFinished(file: String) {
        DispatchQueue.global(qos: .utility).async {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return }
            let edits = ClaudeEdits.latestEdits(jsonl: text)
            let edited = ClaudeEdits.editedPaths(jsonl: text)
            guard !edits.isEmpty || !edited.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self else { return }
                    if !edits.isEmpty { self.claudeEdits = edits } // a turn without edits keeps the last marks
                    self.claudeEditedPaths = edited
                    for editor in EditorTabs.all() {
                        self.deliverClaudeChanges(to: editor)
                    }
                }
            }
        }
    }

    /// Works out the marks for the files of `editor`'s project (off the main thread) and gives them to the tab.
    func deliverClaudeChanges(to editor: any EditorTab) {
        let home = NSHomeDirectory()
        editor.showClaudeFiles(claudeEditedPaths.compactMap {
            PathLinks.relative(SessionMatch.normalize($0, home: home), inRoot: editor.root)
        })
        let edits = claudeEdits
        let root = editor.root
        guard !edits.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak editor] in
            let files = FileService(root: root)
            var changes: [String: [FileEdit.Change]] = [:]
            for edit in edits {
                guard let relative = PathLinks.relative(SessionMatch.normalize(edit.path, home: NSHomeDirectory()), inRoot: root) else { continue }
                changes[relative, default: []].append(edit.change)
            }
            var marks: [String: [LineMark]] = [:]
            for (relative, list) in changes {
                guard let document = try? files.read(relative) else { continue }
                let found = ChangeMarks.marks(in: document.text, changes: list)
                if !found.isEmpty { marks[relative] = found }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { editor?.showClaudeChanges(marks) }
            }
        }
    }

    // MARK: Editor chat

    /// A Razor Code tab's file or selection changed: the composer's chip follows it while that tab is in front.
    func chatContextChanged(_ owner: GlancePaneOwner) {
        if owner === keyController { updateChatContext() }
    }

    /// Every terminal split, front window first and its focused split first: the order `ChatRoute` prefers.
    private func terminalSurfaces() -> [(view: Ghostty.SurfaceView, info: ChatRoute.Surface)] {
        var result: [(view: Ghostty.SurfaceView, info: ChatRoute.Surface)] = []
        for window in NSApp.orderedWindows {
            guard let controller = window.windowController as? BaseTerminalController else { continue }
            let focused = controller.focusedSurface
            let views = Array(controller.surfaceTree).sorted { a, b in a === focused && b !== focused }
            for view in views {
                let process = view.surfaceModel?.foregroundPID.flatMap { ProcessArguments.read(pid: $0) }
                result.append((view, ChatRoute.Surface(pwd: view.pwd, executable: process?.executable,
                                                       arguments: process?.arguments ?? [])))
            }
        }
        return result
    }

    private func updateChatContext() {
        guard let razor = keyController as? RazorWindowController else {
            chatRoot = nil
            session?.chatComposer(nil)
            return
        }
        if chatRoot != razor.root {
            chatRoot = razor.root
            awaitingTerminalPrompt = nil
            chatNotice = nil
            chatFeed.follow(nil, root: nil)
            refreshChatSessions()
        }
        let route = ChatRoute.decide(root: razor.root, surfaces: terminalSurfaces().map(\.info))
        session?.chatComposer(ChatComposer(
            context: ChatMessage.context(file: razor.web.openPath, lines: razor.web.selectedLines),
            route: route, working: chats.isWorking(root: razor.root), notice: chatNotice,
            sessions: chatEntries, activeSession: chats.sessionID(root: razor.root)))
    }

    private func refreshChatSessions() {
        chatEntries = chatRoot.map { chats.entries(root: $0) } ?? []
    }

    /// The composer was focused: show the chat's own conversation (the active session's transcript) if none is shown
    /// yet. Not the project's newest transcript: that may be a session running in another terminal app.
    private func chatOpen() {
        guard let root = chatRoot else { return }
        if chatFeed.file == nil, let id = chats.sessionID(root: root), let path = ChatFeed.locate(id: id) {
            chatFeed.follow(path, root: root)
        }
        refreshChatSessions()
        updateChatContext()
    }

    /// The picker chose a session: the thread shows it and the next message resumes it.
    private func chatSwitch(_ id: String) {
        guard let root = chatRoot, !chats.isWorking(root: root) else { return }
        chats.activate(id, root: root)
        awaitingTerminalPrompt = nil
        chatNotice = nil
        chatFeed.follow(ChatFeed.locate(id: id), root: root)
        refreshChatSessions()
        updateChatContext()
    }

    /// The Terminal side bar's History › View as Threads: brings the project's editor tab to the front and shows the
    /// session's conversation in its chat, one collapsible thread per prompt. Typing there resumes the session.
    func showHistoryThreads(sessionID: String, folder: String) {
        guard let editor = GlanceTabHost.controllers(kind: EditorKind.studio.rawValue).first(where: { $0.tabKey == folder }),
              let window = editor.window else { return }
        window.makeKeyAndOrderFront(nil)
        window.tabGroup?.selectedWindow = window
        // The editor becomes the key controller on the next turn; the chat context follows it.
        DispatchQueue.main.async { [weak self] in
            guard let self, let root = self.chatRoot, root == folder, !self.chats.isWorking(root: root) else { return }
            self.chats.adopt(sessionID, root: root)
            self.awaitingTerminalPrompt = nil
            self.chatNotice = nil
            self.chatFeed.follow(ChatFeed.locate(id: sessionID), root: root)
            self.refreshChatSessions()
            self.updateChatContext()
        }
    }

    private func chatSend(_ text: String, withContext: Bool) {
        guard let razor = keyController as? RazorWindowController else { return }
        let context = withContext ? ChatMessage.context(file: razor.web.openPath, lines: razor.web.selectedLines) : nil
        chatNotice = nil
        sendToProjectClaude(ChatMessage.compose(text, context: context), root: razor.root)
        updateChatContext()
    }

    /// Sends `message` to Claude in `root`: its terminal session when a split there runs Claude Code, else Glance's
    /// headless session for the project (the editor chat and the PR pages both send this way). With `window`, the
    /// Glance pane opens there so the answer shows. The route it took comes back. It's nil when the headless session
    /// is mid-answer: it takes one message at a time, so this one went nowhere.
    @discardableResult
    func sendToProjectClaude(_ message: String, root: String, showIn window: NSWindow? = nil) -> ChatRoute? {
        let surfaces = terminalSurfaces()
        var route: ChatRoute?
        if case .terminal(let index) = ChatRoute.decide(root: root, surfaces: surfaces.map(\.info)),
           let model = surfaces[index].view.surfaceModel {
            // A paste, then Return a moment later so Claude Code sees a keypress, not more pasted text.
            model.sendText(message)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                model.sendKeyEvent(Ghostty.Input.KeyEvent(key: .enter, action: .press))
            }
            awaitingTerminalPrompt = root
            route = .terminal(index: index)
        } else if !chats.isWorking(root: root) {
            chats.send(message, root: root)
            AgentsActivity.shared.set("chat:" + root, running: chats.isWorking(root: root))
            route = .headless
        }
        if let owner = window?.windowController as? GlancePaneOwner, !owner.glancePaneOpen {
            setPaneOpen(true, in: owner)
        }
        return route
    }

    /// Stops the turn `sendToProjectClaude` started in `root`: Esc in its terminal session, or the headless turn ends.
    func stopProjectClaude(root: String) {
        let surfaces = terminalSurfaces()
        if case .terminal(let index) = ChatRoute.decide(root: root, surfaces: surfaces.map(\.info)),
           let model = surfaces[index].view.surfaceModel {
            model.sendKeyEvent(Ghostty.Input.KeyEvent(key: .escape, action: .press))
        } else {
            chats.stop(root: root)
        }
    }

    /// Reads `markdown` aloud in the Glance pane's voice (the PR page's Read aloud).
    func readAloud(_ markdown: String) {
        session?.readAloud(markdown)
    }

    /// The orb channel's `tell` (spec "Telling the user"): `markdown` on Glance's card above the orb (or in the side
    /// bar), sized by `size`, read aloud when `speak`. With Studio behind another app, a card at the top says so too;
    /// its Open brings Studio forward with the card open. `asked`: the question it answers (the orb assistant's), shown
    /// muted above it.
    func tell(_ markdown: String, size: TellCard.Size, speak: Bool, from channel: ChannelBook.Session,
              asked: String? = nil) {
        guard let session else { return }
        let layout = GlanceLayoutModel.shared
        // Only the floating card takes the tell's size and folds; in the side bar it's just shown.
        if keyController?.glancePlacement == .floating { layout.beginTell(size: size) } else { layout.endTell() }
        if keyController?.glancePaneOpen != true { setPaneOpen(true) } else if isFloating { layout.cardOpen = true }
        showingTell = true
        session.tell(markdown, narrate: speak, asked: asked)
        showingTell = false
        guard !NSApp.isActive else { return }
        var notice = ChannelNotices.message(id: "orb-" + UUID().uuidString, label: channel.label,
                                            surface: channel.surface, cwd: channel.projectDir,
                                            title: TellCard.headline(markdown), body: nil, date: Date())
        notice.meta[Self.openCardMeta] = "1"
        NotificationHub.shared.post(notice)
    }

    /// A notice's `meta` key: its Open shows Glance's card (a `tell` made while Studio was behind).
    static let openCardMeta = "glanceCard"

    /// Opens Glance's card in the key window (or its side bar), once the window a notice's Open focused is key.
    func showCard() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let controller = self.keyController else { return }
            if !controller.glancePaneOpen { self.setPaneOpen(true, in: controller) }
            else if self.isFloating { GlanceLayoutModel.shared.cardOpen = true }
        }
    }

    /// Stop: Esc in the terminal's Claude, or end the headless turn.
    private func chatStop() {
        guard let root = chatRoot else { return }
        stopProjectClaude(root: root)
        updateChatContext()
    }

    /// A blank chat: the session stays in the picker, the next message starts a new one.
    private func chatNew() {
        guard let root = chatRoot, !chats.isWorking(root: root) else { return }
        chats.startBlank(root: root)
        awaitingTerminalPrompt = nil
        chatNotice = nil
        chatFeed.follow(nil, root: nil)
        refreshChatSessions()
        updateChatContext()
    }

    private func chatEvent(_ root: String, _ event: ChatSessions.Event) {
        // Started, finished, failed (Claude missing included), stopped: the dot follows the run.
        AgentsActivity.shared.set("chat:" + root, running: chats.isWorking(root: root))
        FixJobs.shared.chat(root: root, event: event)
        switch event {
        case .started: break // the transcript's first prompt starts the feed (chatTranscriptEvent)
        case .finished: if root == chatRoot { chatNotice = nil }
        case .failed(let message): if root == chatRoot { chatNotice = message }
        }
        if root == chatRoot {
            refreshChatSessions()
            updateChatContext()
        }
    }

    /// A prompt in a transcript: the headless session's own, or the terminal session a message just went to.
    private func chatTranscriptEvent(_ event: TranscriptWatcher.Event) {
        guard event.kind == .prompt, let root = chatRoot else { return }
        if let id = chats.sessionID(root: root), event.file.hasSuffix("/\(id).jsonl") {
            chatFeed.follow(event.file, root: root)
            refreshChatSessions() // its first prompt names it
            updateChatContext()
        } else if awaitingTerminalPrompt == root, SessionMatch.matches(sessionCwd: event.cwd, surfacePwd: root) {
            awaitingTerminalPrompt = nil
            chatFeed.follow(event.file, root: root)
        }
    }

    // MARK: Focus

    /// A terminal window's focused split, its folder, or key status changed.
    func focusChanged(_ controller: GlancePaneOwner) {
        TabSidebarModel.shared.refreshSoon(tabBar: false) // a tab's folder or focus changed: its sidebar row may too
        guard controller.window?.isKeyWindow == true else { return }
        TabSidebarModel.shared.visit(folder: controller.glanceDirectory)
        keyController = controller
        if controller is BaseTerminalController || controller is any EditorTab {
            HomeTabs.recordProject(from: controller.glanceDirectory) // Home's Recent list
        }
        updateChatContext()
        placeWebView()
        let pwd = controller.glanceDirectory
        dictation.latestCwd = pwd
        apply(router.focus(Self.routerFocus(controller)))
        summaryFocusChanged()
    }

    /// What the pane follows for this window: its focused terminal split, nothing for an editor, else its folder.
    private static func routerFocus(_ controller: GlancePaneOwner) -> SessionRouter.Focus {
        if let terminal = controller as? BaseTerminalController, let surface = terminal.focusedSurface {
            return .terminal(surface: surface.id, pwd: surface.pwd)
        }
        if controller is any EditorTab { return .editor(root: controller.glanceDirectory) }
        return .folder(controller.glanceDirectory)
    }

    /// Coming back to Glance Studio means looking at the key window's folder again.
    @objc private func appBecameActive() {
        TabSidebarModel.shared.visit(folder: keyController?.glanceDirectory)
    }

    @objc private func windowBecameKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow { HomeTabs.windowBecameKey(window) } // Home at launch
        guard let controller = (notification.object as? NSWindow)?.windowController as? GlancePaneOwner else { return }
        focusChanged(controller)
    }

    // MARK: The pane

    func slotsChanged() {
        slots.removeAll { $0.value?.window == nil }
        for slot in NSApp.windows.flatMap({ Self.slots(in: $0.contentView) }) where !slots.contains(where: { $0.value === slot }) {
            slots.append(.init(slot))
        }
        placeWebView()
    }

    /// Moves the one web panel into the key window's pane, with the chrome of the pane it's in: the floating card's
    /// (no header, a hover strip) or the side bar's.
    private func placeWebView() {
        guard let view = session?.view, let window = keyController?.window,
              let slot = slots.compactMap(\.value).first(where: { $0.window === window }) else { return }
        session?.setFloatingChrome(slot.floating)
        guard view.superview !== slot else { return }
        view.removeFromSuperview()
        view.frame = slot.bounds
        view.autoresizingMask = [.width, .height]
        slot.addSubview(view)
        session?.appear()
    }

    private static func slots(in view: NSView?) -> [GlancePaneSlot] {
        guard let view else { return [] }
        if let slot = view as? GlancePaneSlot { return [slot] }
        return view.subviews.flatMap { slots(in: $0) }
    }

    /// The window in front shows Glance as the floating orb.
    private var isFloating: Bool {
        keyController?.glancePaneOpen == true && keyController?.glancePlacement == .floating
    }

    /// Opens or closes Glance in `controller`'s window (the key window's by default). Opening it as the floating orb
    /// opens its card too; closing it closes it completely.
    private func setPaneOpen(_ open: Bool, in controller: GlancePaneOwner? = nil) {
        guard let controller = controller ?? keyController else { return }
        controller.glancePaneOpen = open
        Self.paneOpenDefault = open
        GlanceLayoutModel.shared.cardOpen = open && controller.glancePlacement == .floating
        GlanceLayoutModel.shared.paneOpenChanged()
        if !open { session?.stop() }
    }

    /// The top bar's Glance button.
    func toggleGlance(in window: NSWindow?) {
        guard let controller = window?.windowController as? GlancePaneOwner else { return }
        setPaneOpen(!controller.glancePaneOpen, in: controller)
    }

    // MARK: Menu and keys

    /// ⌥Space: the floating card opens and closes; otherwise Glance does.
    @objc func togglePane() {
        if isFloating {
            GlanceLayoutModel.shared.cardOpen.toggle()
        } else {
            setPaneOpen(!(keyController?.glancePaneOpen ?? false))
        }
    }

    @objc func playPause() {
        session?.playPause()
    }

    /// Glance's settings, which the Settings tab shows: the Studio session's.
    var settings: SettingsModel? { session?.settings }

    /// Opens the Settings tab in the window in front (a window of its own when there's none), on `section` when given.
    func showSettings(_ section: SettingsSection? = nil) {
        SettingsTabController.open(section: section, from: SettingsTabController.frontWindow)
    }

    /// Reopened with the terminal off: the overlay's panel when it's on, else Settings so the switch can be turned back on.
    func reopenWithoutTerminal() {
        if let overlay, Prefs.surfaces.overlay { overlay.showPanel() } else { showSettings() }
    }

    @objc func toggleTabSidebar() {
        TabSidebarModel.shared.isOpen.toggle()
    }

    /// File › New Editor Tab (⇧⌘E), the Editor side bar's buttons and Home's: the Open in Editor palette asks which
    /// folder, then opens a new tab, even with that project open already.
    @objc func newEditorTab() {
        let parent = NSApp.keyWindow
        let thisTab = (parent?.windowController as? GlancePaneOwner)?
            .glanceDirectory.flatMap { $0.isEmpty ? nil : ProjectRoot.find(from: $0) }
        OpenInEditorPalette.show(over: parent, thisTab: thisTab)
    }

    /// File › New Pull Request (⌥⌘P): the key window's project's New pull request tab.
    @objc func newPullRequest() {
        NewPullRequestWindowController.openForKeyWindow()
    }

    /// View › Review Comments: the inbox of the key window's project.
    @objc func showReviewComments() {
        ReviewInboxWindowController.openForKeyWindow()
    }

    /// File → Home (⇧⌘H): the key window's Home tab, opened if needed.
    @objc func showHome() {
        HomeTabs.show(in: NSApp.keyWindow)
    }

    /// The tab sidebar's and the top bar's Home entries: their window (the notification's object) or the key one.
    /// Glance browser (spec 2026-10-14-agent-browser-design.md): its two ports listen from launch and start the
    /// broker on first use; a page opening shows the panel.
    private func startAgentBrowser() {
        let broker = AgentBrowserBroker.shared
        broker.quitsWhenIdle = BrowserData.agentBrowserQuitsWhenIdle
        broker.keepAlive = { AgentBrowserPanel.shared.isShown || !AgentBrowserModel.shared.pages.isEmpty }
        AgentBrowserModel.shared.onPageOpened = {
            if BrowserData.showsAgentBrowser, !AgentBrowserPanel.shared.isShown { AgentBrowserPanel.shared.show() }
        }
        broker.startListening()
    }

    @objc func toggleAgentBrowser() { AgentBrowserPanel.shared.toggle() }

    @objc func quickNote() { QuickNotePanel.shared.show() }

    @objc private func showHomeRequested(_ notification: Notification) {
        HomeTabs.show(in: notification.object as? NSWindow ?? NSApp.keyWindow)
    }

    private func installMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        if let view = mainMenu.items.first(where: { $0.submenu?.title == "View" })?.submenu {
            view.addItem(.separator())
            let pane = NSMenuItem(title: "Glance Panel", action: #selector(togglePane), keyEquivalent: " ")
            pane.keyEquivalentModifierMask = .option
            pane.target = self
            view.addItem(pane)
            let voice = NSMenuItem(title: "Play/Pause Narration", action: #selector(playPause), keyEquivalent: ".")
            voice.keyEquivalentModifierMask = .option
            voice.target = self
            view.addItem(voice)
            let tabs = NSMenuItem(title: "Side Bar", action: #selector(toggleTabSidebar), keyEquivalent: "l")
            tabs.keyEquivalentModifierMask = [.command, .shift]
            tabs.target = self
            view.addItem(tabs)
            ProjectSwitchMenu.shared.install(in: view)
            let comments = NSMenuItem(title: "Review Comments", action: #selector(showReviewComments),
                                      keyEquivalent: "")
            comments.target = self
            view.addItem(comments)
            // Notifications (⇧⌘N), while the feature is on.
            NotificationsMenu.shared.install(in: view)
            // Tickets (⌥⌘T), while the feature is on.
            TicketsMenu.shared.install(in: view)
            if StudioFeatures.shared.isOn(.browser) {
                let agent = NSMenuItem(title: "Glance Browser", action: #selector(toggleAgentBrowser), keyEquivalent: "b")
                agent.keyEquivalentModifierMask = [.command, .option]
                agent.target = self
                view.addItem(agent)
            }
        }
        if let file = mainMenu.items.first(where: { $0.submenu?.title == "File" })?.submenu {
            let editor = NSMenuItem(title: "New Editor Tab", action: #selector(newEditorTab), keyEquivalent: "e")
            editor.keyEquivalentModifierMask = [.command, .shift]
            editor.target = self
            file.insertItem(editor, at: min(2, file.items.count))
            // ⌃⌥N works from any app (a system-wide shortcut); the item shows it and opens it from Studio.
            let note = NSMenuItem(title: "Quick Note", action: #selector(quickNote), keyEquivalent: "n")
            note.keyEquivalentModifierMask = [.control, .option]
            note.target = self
            file.insertItem(note, at: min(3, file.items.count))
            // Razor Code's own items; a GS Code tab's VS Code takes these keys first.
            let save = NSMenuItem(title: "Save", action: Selector(("glanceEditorSave:")), keyEquivalent: "s")
            let open = NSMenuItem(title: "Quick Open…", action: Selector(("glanceEditorQuickOpen:")), keyEquivalent: "p")
            file.insertItem(save, at: min(3, file.items.count))
            file.insertItem(open, at: min(4, file.items.count))
            let find = NSMenuItem(title: "Find in Project…", action: Selector(("glanceEditorFindInProject:")), keyEquivalent: "f")
            find.keyEquivalentModifierMask = [.command, .shift]
            file.insertItem(find, at: min(5, file.items.count))
            let next = NSMenuItem(title: "Next Claude Change", action: Selector(("glanceEditorNextChange:")), keyEquivalent: "")
            let previous = NSMenuItem(title: "Previous Claude Change", action: Selector(("glanceEditorPreviousChange:")), keyEquivalent: "")
            let clear = NSMenuItem(title: "Clear Claude Change Marks", action: Selector(("glanceEditorClearChanges:")), keyEquivalent: "")
            file.insertItem(next, at: min(6, file.items.count))
            file.insertItem(previous, at: min(7, file.items.count))
            file.insertItem(clear, at: min(8, file.items.count))
            let home = NSMenuItem(title: "Home", action: #selector(showHome), keyEquivalent: "h")
            home.keyEquivalentModifierMask = [.command, .shift]
            home.target = self
            file.insertItem(home, at: min(3, file.items.count))
            let pull = NSMenuItem(title: "New Pull Request", action: #selector(newPullRequest), keyEquivalent: "p")
            pull.keyEquivalentModifierMask = [.command, .option]
            pull.target = self
            file.insertItem(pull, at: min(4, file.items.count))
        }
        // Edit › Cut (⌘X): Ghostty's Edit menu has none, so nothing outside a terminal (fields, the Browser) could cut.
        if let edit = mainMenu.items.first(where: { $0.submenu?.title == "Edit" })?.submenu,
           !edit.items.contains(where: { $0.action == #selector(NSText.cut(_:)) }) {
            let index = edit.items.firstIndex { $0.action == #selector(NSText.copy(_:)) } ?? edit.items.count
            edit.insertItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"), at: index)
        }
        // Edit › To-dos… and Notes…: what Ask Claude saved from selections, viewable without a selection.
        if let edit = mainMenu.items.first(where: { $0.submenu?.title == "Edit" })?.submenu,
           !edit.items.contains(where: { $0.action == #selector(showSavedTodos) }) {
            edit.addItem(.separator())
            let todos = NSMenuItem(title: "To-dos…", action: #selector(showSavedTodos), keyEquivalent: "")
            todos.target = self
            edit.addItem(todos)
            let notes = NSMenuItem(title: "Notes…", action: #selector(showSavedNotes), keyEquivalent: "")
            notes.target = self
            edit.addItem(notes)
        }
        // Settings… (⌘,) opens the Settings tab; the terminal's config file moves to the item under it.
        if let app = mainMenu.items.first?.submenu,
           let index = app.items.firstIndex(where: { $0.action == #selector(AppDelegate.openConfig(_:)) }) {
            app.items[index].title = "Settings…"
            let file = NSMenuItem(title: "Open Config File…", action: #selector(AppDelegate.openConfigFile(_:)),
                                  keyEquivalent: "")
            app.insertItem(file, at: index + 1)
        }
        // Help › Welcome to Glance Studio… replays First Light (onboarding).
        if let help = mainMenu.items.first(where: { $0.submenu?.title == "Help" })?.submenu {
            let welcome = NSMenuItem(title: "Welcome to Glance Studio…", action: #selector(showWelcome),
                                     keyEquivalent: "")
            welcome.target = self
            help.insertItem(welcome, at: 0)
            help.insertItem(.separator(), at: 1)
        }
        DevelopMenu.shared.install(in: mainMenu)
    }

    @objc func showSavedTodos() { _ = CapturesTabController.open(.todos, from: NSApp.keyWindow) }

    @objc func showSavedNotes() { _ = CapturesTabController.open(.notes(nil), from: NSApp.keyWindow) }

    @objc func showWelcome() {
        OnboardingWindowController.show {
            if TerminalController.all.isEmpty && Prefs.surfaces.opensWindowAtLaunch {
                (NSApp.delegate as? AppDelegate)?.newWindow(nil)
            }
        }
    }
}
