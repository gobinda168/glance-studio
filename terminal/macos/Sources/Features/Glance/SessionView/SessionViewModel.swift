import AppKit
import Combine
import GlanceCore
import GlanceKit

/// One tab's Glance view state: which Claude session the tab's focused split runs, its timeline, any waiting prompt,
/// and the side panel's facts. Follows the session when it changes (/clear, a new claude).
@MainActor
final class SessionViewModel: ObservableObject {
    @Published private(set) var link: SessionLink?
    @Published private(set) var timeline = SessionTimeline(root: nil)
    @Published private(set) var blocks: [TimelineBlock] = []
    /// The prose rows that end a finished turn.
    @Published private(set) var finishedReplies: Set<String> = []
    @Published private(set) var prompt: PendingPrompt?
    @Published private(set) var branch: String?
    @Published private(set) var changes: WorkingChanges.Summary?
    @Published var queued: [String] = []
    /// Claude Code's footer as last read: the permission mode and effort as they are now.
    @Published private(set) var footer: SessionFooter?
    /// A permission mode switch is pressing keys.
    @Published private(set) var switchingMode = false
    /// The mode a switch couldn't reach, until the next try or another session.
    @Published private(set) var modeFailure: PermissionMode?
    /// The prompt (by its tool call) the user has answered from the Glance view, until Claude moves on.
    @Published private(set) var answeredCall: String?
    /// The link changed while the view was open (/clear, a new claude): the timeline shows a "New session" divider.
    @Published private(set) var newSession = false
    @Published private(set) var newSessionAt: Date?
    /// Glance started `claude` in this split and its session isn't linked yet; messages typed meanwhile wait in `held`.
    @Published private(set) var starting = false
    /// Text for the composer to take once (the proof "Update setup" button): it shows there as a draft, not sent.
    @Published var composerDraft: String?
    /// Text to add to what's typed, and take the keyboard: an explainer's Ask about this. Never sent.
    @Published var composerAddition: String?
    /// The `claude` process of the linked session, the key to its windows in the Glance browser (it outlives `/clear`).
    /// Found off the main thread when the link changes; nil until then, outside Claude, or when nothing knows it.
    @Published private(set) var claudePID: Int32?

    // MARK: A finished worktree's recap (command center)

    /// A finished worktree's recap, shown instead of a timeline until a session starts here.
    @Published private(set) var recap: WorktreeRecap?
    /// The recap goes ahead of the first message (the composer's switch).
    @Published var recapAsContext = true
    /// Why the last recap action (resume, recreate, summarize) didn't work.
    @Published private(set) var recapMessage: String?
    /// Why the first message couldn't start a session (too long to type): the composer shows it and keeps the text.
    @Published private(set) var sendFailure: String?
    /// The recap's git, summaries and spend are still being read.
    @Published private(set) var recapLoading = false
    @Published private(set) var summarizing = false
    /// Summarize with Claude works through a few sessions one at a time: how many are done of how many asked for.
    @Published private(set) var summaryProgress: (done: Int, total: Int)?
    @Published private(set) var recreating = false

    /// Whether the last session can be brought back with `claude --resume`, and from where. Found off the main thread: it
    /// looks at the disk.
    enum ResumeOffer: Equatable {
        case checking
        case unavailable
        case available(RecapText.Resume)
    }
    @Published private(set) var resumeOffer: ResumeOffer = .checking

    /// The session's proof of work: its record, the project's setup, its PR.
    let proof = ProofModel()
    /// The session's images and videos, grouped by where they came from.
    let assets = AssetsModel()
    /// This session's explainers (spec 2026-11-03-explainer-mode-design.md).
    let explainers = ExplainerModel()

    let surface: UUID
    /// The view lives inside the controller's window, so the model must not keep the controller alive.
    weak var controller: BaseTerminalController?

    // deinit is nonisolated: the feed (main-actor) is stopped from a main-actor task, the tokens are removed in place.
    private let feed = TimelineFeed()
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private var returnAfter: (command: String, rows: Int)?
    /// The row count when each queued message was sent, so only a user row that arrives afterwards takes it off the queue.
    private var queuedMarks: [Int] = []
    private var flippingToTerminal = false
    private var modeToken: AnyCancellable?
    private var readingChanges = false
    /// The folder `changes` describes.
    private var changesFolder: String?
    private var held: [String] = []
    /// The message `claude` was started with, shown as queued until its row lands.
    private var launchPrompt: String?
    private var startedAt: Date?
    /// Counts relinks, so a slow lookup for an earlier link doesn't overwrite a newer one.
    private var pidLookups = 0
    private var wasWorking = false
    private var pwdToken: AnyCancellable?
    /// The sessions Summarize with Claude asked for and is waiting on.
    private var summaryQueue: [SessionLink] = []
    private var summaryCurrent: SessionLink?
    /// The recap read in flight, and the wait before a summary that landed makes it read again (several landing together
    /// make one read).
    private var loadCancel: LoadCancel?
    private var reloadWork: DispatchWorkItem?
    /// Count the recap reads and resume lookups, so a slow one for an earlier recap doesn't overwrite a newer one.
    private var recapLoads = 0
    private var resumeLookups = 0
    private nonisolated static let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects").path

    /// `chosen`: the split to follow, when it isn't the focused one (the board opens the split a session runs in).
    init(controller: BaseTerminalController, surface chosen: UUID? = nil) {
        self.controller = controller
        surface = chosen ?? controller.focusedSurface?.id ?? controller.surfaceTree.map(\.id).first ?? UUID()
        feed.onChange = { [weak self] in self?.apply($0) }
        explainers.insertInComposer = { [weak self] in self?.composerAddition = $0 }
        explainers.openFile = { [weak self] path in
            guard let window = self?.controller?.window ?? NSApp.keyWindow else { return }
            _ = GlanceEditorHost.openFromPane(path, from: window, directory: self?.cwd)
        }
        explainers.isFront = { [weak self] in NSApp.isActive && self?.controller?.window?.isKeyWindow == true }
        explainers.checks = { [weak self] in self?.proof.record?.checks ?? [] }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .glanceSessionLinksChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.relink() }
        })
        observers.append(center.addObserver(forName: .glancePromptsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reprompt() }
        })
        observers.append(center.addObserver(forName: .summaryChanged, object: nil, queue: .main) { [weak self] note in
            let session = note.userInfo?["session"] as? String
            MainActor.assumeIsolated { self?.summaryChanged(session) }
        })
        // Flipping to the terminal any other way (⌥⌘G, the switch, Show Terminal) cancels a pending flip back.
        modeToken = controller.$glanceMode.dropFirst().sink { [weak self] on in
            guard let self, !on, !self.flippingToTerminal else { return }
            self.returnAfter = nil
        }
        relink()
        reprompt()
        proof.attach(self)
        assets.attach(self)
        followPwd()
        proof.reload()
    }

    /// The split's own directory counts as the folder when no session is linked (`cwd`), so a `cd` there moves Assets too.
    private func followPwd() {
        guard let view = controller?.surfaceTree.first(where: { $0.id == surface }) else { return }
        pwdToken = view.$pwd.removeDuplicates().sink { [weak self] _ in
            // `$pwd` publishes before the value changes: look once it has.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.assets.folderMayHaveChanged() } }
        }
    }

    /// Stops following the transcript and drops the observers; the controller calls it when its window closes.
    func shutdown() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        modeToken = nil
        loadCancel?.cancel()
        reloadWork?.cancel()
        feed.onChange = nil
        feed.stop()
        proof.stop()
        assets.stop()
        explainers.stop()
        pwdToken = nil
    }

    // The safety net when the controller never got to shutdown().
    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        let feed = feed
        Task { @MainActor in feed.stop() }
    }

    private func relink() {
        let next = GlanceTerminalHost.shared.sessionLink(for: surface)
        guard next != link else { return }
        if link != nil, let next, next.sessionID != link?.sessionID {
            newSession = true
            newSessionAt = Date()
        }
        // The proof of the old session or repository must not show on the new one, even for a moment.
        proof.followChanged(sessionChanged: next?.sessionID != link?.sessionID, folderChanged: next?.cwd != link?.cwd)
        assets.followChanged(sessionChanged: next?.sessionID != link?.sessionID, folderChanged: next?.cwd != link?.cwd)
        explainers.follow(session: next?.sessionID, cwd: next?.cwd)
        link = next
        timeline = SessionTimeline(root: next?.cwd)
        blocks = []
        finishedReplies = []
        queued = []
        queuedMarks = []
        footer = nil
        modeFailure = nil
        returnAfter = nil
        feed.follow(next?.transcriptPath, root: next?.cwd)
        refreshFolderFacts()
        refreshClaudePID()
        proof.reload()
        assets.folderMayHaveChanged()
        followPwd()
        if next != nil {
            starting = false
            // A session started here takes over from the recap.
            if recap != nil {
                recap = nil
                recapMessage = nil
                sendFailure = nil
                summaryQueue = []
                summaryCurrent = nil
                summaryProgress = nil
                loadCancel?.cancel()
                reloadWork?.cancel()
                summarizing = false
                recreating = false
                recapLoads += 1
                recapLoading = false
            }
            deliverHeld()
        }
    }

    /// Now that the session Glance started is linked: its first message and the ones typed while it started show as
    /// queued until their rows land; the typed ones go in a moment apart (Claude's prompt may still be drawing).
    private func deliverHeld() {
        let messages = held
        let shown = (launchPrompt.map { [$0] } ?? []) + messages
        held = []
        launchPrompt = nil
        guard !shown.isEmpty else { return }
        queued = shown
        queuedMarks = shown.map { _ in 0 }
        let surface = surface
        for (i, text) in messages.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(i) * 0.6) {
                MainActor.assumeIsolated { _ = SessionInput.send(text, to: surface) }
            }
        }
    }

    /// The surface's foreground process is read here (it needs the terminal), then the process check and the ledger
    /// (files) are read on a background queue.
    private func refreshClaudePID() {
        pidLookups += 1
        guard let next = link else { claudePID = nil; return }
        let lookup = pidLookups
        let foreground = controller?.surfaceTree.first(where: { $0.id == surface })?.surfaceModel?.foregroundPID.flatMap(Int32.init(exactly:))
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let pid = SessionClaudePID.find(foregroundPID: foreground, sessionID: next.sessionID, cwd: next.cwd)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.pidLookups == lookup, self.claudePID != pid else { return }
                    self.claudePID = pid
                }
            }
        }
    }

    private func reprompt() { prompt = NeedsYouStudio.shared.prompt(forSurface: surface) }

    private func apply(_ t: SessionTimeline) {
        timeline = t
        blocks = TimelineLayout.blocks(t.rows)
        let finished = ExplainerTurns.finishedReplies(t.rows, working: t.live.working)
        if finished != finishedReplies { finishedReplies = finished }
        explainers.timelineChanged(t)
        // A queued message leaves the queue once Claude takes it as a prompt: a user row that arrived after it was
        // queued, with the same text, one row per message, oldest first.
        if !queued.isEmpty {
            var claimed = Set<Int>(), keep: [Int] = []
            for (i, text) in queued.enumerated() {
                let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let mark = i < queuedMarks.count ? queuedMarks[i] : 0
                let hit = t.rows.indices.dropFirst(mark).first { index in
                    !claimed.contains(index) && t.rows[index].kind.takes(queued: wanted)
                }
                if let hit { claimed.insert(hit) } else { keep.append(i) }
            }
            if keep.count != queued.count {
                queuedMarks = keep.map { $0 < queuedMarks.count ? queuedMarks[$0] : 0 }
                queued = keep.map { queued[$0] }
            }
        }
        if let r = returnAfter, t.rows.count > r.rows,
           t.rows.dropFirst(r.rows).contains(where: { if case .command(let name, _) = $0.kind { return name == "/" + r.command }; return false }) {
            returnAfter = nil
            if let controller { GlanceMode.set(true, in: controller) }
        }
        if !t.live.working { refreshFolderFacts() }
        if wasWorking && !t.live.working { assets.claudeWentIdle() }
        wasWorking = t.live.working
        proof.timelineChanged(t)
    }

    /// The branch (a small file read) and the working-changes count (git, off the main thread) of the session's folder.
    private func refreshFolderFacts() {
        // A recap of a removed worktree has no folder to read: it keeps the branch it was on, for its PR.
        guard let cwd = factsFolder else { branch = recap?.branch; changes = nil; changesFolder = nil; return }
        let head = GitHead.branch(inFolder: cwd)
        if branch != head { branch = head }
        if changesFolder != cwd { changesFolder = cwd; changes = nil }
        guard !readingChanges else { return }
        readingChanges = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let summary = WorkingChanges.read(folder: cwd)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.readingChanges = false
                    // A read for a folder the tab has since left is dropped, and the new folder is read now.
                    if self.factsFolder == cwd { if self.changes != summary { self.changes = summary } }
                    else { self.refreshFolderFacts() }
                }
            }
        }
    }

    /// The folder the branch and changes are read from: the session's, else a recap's worktree while it is there.
    private var factsFolder: String? { link?.cwd ?? recap.flatMap { $0.exists ? $0.worktree : nil } }

    // MARK: Input

    /// False when the terminal couldn't take the text.
    func send(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if sendFailure != nil { sendFailure = nil }
        guard link != nil else { return start(with: trimmed) }
        let sent = SessionInput.send(trimmed, to: surface)
        if sent, timeline.live.working {
            queued.append(trimmed)
            queuedMarks.append(timeline.rows.count)
        }
        return sent
    }

    /// A message from a proof button; with no session it starts Claude with it.
    /// False when the terminal couldn't take it.
    @discardableResult
    func askClaude(_ prompt: String) -> Bool { send(prompt) }

    func stop() { _ = SessionInput.interrupt(surface) }
    func startClaude() {
        if SessionInput.startClaude(in: surface) { claudeLaunched() }
    }

    /// No session in the split yet: the first message starts Claude with it, or waits for the Claude already starting.
    private func start(with text: String) -> Bool {
        if starting {
            held.append(text)
            queued.append(text)
            queuedMarks.append(0)
            return true
        }
        // With the command center on, the first message is what `RecapText` builds (the recap ahead of the text when the
        // switch is on, the text made safe, over-long refused), and the line typed is built from the same function.
        var first = text
        if StudioFeatures.shared.isOn(.commandCenter) {
            if recap != nil {
                // What is known of the recap is used; before the first of it is, the message waits rather than going without it.
                if recapLoading, recapAsContext {
                    sendFailure = "Still reading the recap. Send again in a moment, or switch the recap off."
                    return false
                }
                // Only a shell takes `claude …`: a Claude already running here (the start timeout can pass with one) would
                // take the whole line as a message.
                if let why = SessionInput.typingRefusal(in: surface, action: "starting a session") {
                    sendFailure = why
                    return false
                }
            }
            switch RecapText.firstMessage(recap: recap, asContext: recapAsContext, text: text) {
            case .success(let message): first = message
            case .failure(let refusal):
                sendFailure = refusal.message
                return false
            }
        }
        guard SessionInput.startClaude(in: surface, prompt: text, recap: recap, asContext: recapAsContext) else { return false }
        claudeLaunched()
        launchPrompt = first
        queued.append(first)
        queuedMarks.append(0)
        return true
    }

    /// `claude` was just typed into this split. If no session links within 30 s (it failed, or Glance's hooks aren't
    /// set up) the view stops saying it's starting; held messages stay queued and still go in if it links later.
    func claudeLaunched() {
        guard link == nil else { return }
        starting = true
        let at = Date()
        startedAt = at
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.startedAt == at, self.link == nil else { return }
                self.starting = false
            }
        }
    }

    /// A fresh conversation in this tab (`/clear`; the old one stays in /resume).
    func clearSession() { _ = SessionInput.send("/clear", to: surface) }

    /// A new tab in the session's folder running its own Claude, in Glance mode.
    func newSessionTab() {
        _ = SessionInput.newSessionTab(folder: cwd ?? NSHomeDirectory(), beside: controller?.window)
    }
    // MARK: Recap

    /// Shows a finished worktree's recap in this tab. What is slow to find (git, summaries, spend) arrives with `updateRecap`.
    func showRecap(_ recap: WorktreeRecap) {
        self.recap = recap
        recapMessage = nil
        recapLoading = true
        proof.reload()
        refreshFolderFacts()
        assets.folderMayHaveChanged()
        refreshResume()
    }

    /// The recap for the worktree this tab shows, as far as it is known: the quick parts come first with the spend still being
    /// read, then the whole. One for another worktree is dropped.
    func updateRecap(_ next: WorktreeRecap) {
        guard let old = recap, old.worktree == next.worktree else { return }
        recapLoading = false
        var next = next
        // A read that began before the worktree was recreated must not bring it back as removed.
        next.exists = next.exists || old.exists
        // The figure we had stays up while it is read again.
        if next.spendPending, next.spend == nil { next.spend = old.spend }
        guard next != old else { return }
        recap = next
        // Which session's proof, and which branch's PR, this is only known once the sessions are: read them again then.
        let moved = next.sessions.first != old.sessions.first || next.branch != old.branch || next.exists != old.exists
        if moved { refreshFolderFacts(); proof.reload(); assets.folderMayHaveChanged() }
        if next.sessions != old.sessions || next.exists != old.exists { refreshResume() }
    }

    /// Reads the recap off the main thread: what a new read replaces is told to stop. The quick parts arrive first.
    func loadRecap(_ input: RecapLoader.Input) {
        recapLoads += 1
        let load = recapLoads
        loadCancel?.cancel()
        let cancel = LoadCancel()
        loadCancel = cancel
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let whole = RecapLoader.load(input, isCancelled: { cancel.isCancelled }, partial: { early in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.recapLoads == load, !cancel.isCancelled else { return }
                        self.updateRecap(early)
                    }
                }
            })
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.recapLoads == load, !cancel.isCancelled else { return }
                    self.updateRecap(whole)
                }
            }
        }
    }

    /// A flag a background read is asked to stop by.
    private final class LoadCancel: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func cancel() { lock.lock(); flag = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }

    /// Whose proof the panel shows: this tab's session, else the recap's last one.
    var proofSession: String? { link?.sessionID ?? recap?.sessions.first }

    /// Looks for a session `claude --resume` can bring back, off the main thread (it reads records and stats folders).
    private func refreshResume() {
        resumeLookups += 1
        guard let snapshot = recap, !snapshot.sessions.isEmpty else { resumeOffer = .unavailable; return }
        let lookup = resumeLookups
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let store = WorkStore()
            var cwds: [String: String] = [:]
            for id in snapshot.sessions { if let cwd = store.record(session: id)?.cwd { cwds[id] = cwd } }
            let found = RecapText.resume(snapshot, cwds: cwds, projects: Self.projects)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.resumeLookups == lookup else { return }
                    self.resumeOffer = found.map(ResumeOffer.available) ?? .unavailable
                }
            }
        }
    }

    /// Where the last session would resume when that isn't this worktree (its transcript is filed under another folder).
    var resumeElsewhere: String? {
        guard case .available(let resume) = resumeOffer, let recap,
              BoardWorktrees.key(resume.folder) != BoardWorktrees.key(recap.worktree) else { return nil }
        return resume.folder
    }

    /// Why "Resume last session" can't be used now, for the button to say; nil when it can.
    var resumeBlocked: String? {
        switch resumeOffer {
        case .checking: "Checking for a session to resume…"
        case .unavailable: "Its transcript isn't there any more, so there is nothing to resume."
        case .available: starting ? "Claude is starting in this tab." : nil
        }
    }

    /// Brings the last session back: `cd` to the folder it started in, then `claude --resume`. Typed only into a shell: a
    /// Claude already running here (the 30 s start timeout can pass with one running) would take it as a message.
    func resumeLast() {
        guard case .available(let resume) = resumeOffer, link == nil, !starting else { return }
        recapMessage = nil
        if let why = SessionInput.typingRefusal(in: surface, action: "resuming") {
            recapMessage = why
            return
        }
        guard SessionInput.send(resume.command, to: surface) else {
            recapMessage = "The terminal couldn't take the command."
            return
        }
        claudeLaunched()
    }

    /// `git worktree add` for a removed worktree, off the main thread, only on the button. On success the shell moves into
    /// it, so a session started next runs there.
    func recreateWorktree() {
        guard let recap, !recap.exists, !recreating else { return }
        guard recap.branchExists != false else {
            recapMessage = "Its branch is gone, so the worktree can't be recreated."
            return
        }
        guard let branch = recap.branch, !branch.isEmpty, let main = recap.main else {
            recapMessage = "Its branch isn't known, so the worktree can't be recreated."
            return
        }
        recapMessage = nil
        recreating = true
        let path = recap.worktree
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let failure = WorktreeActions.recreate(path: path, branch: branch, mainRoot: main)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.recreated(path, failure) } }
        }
    }

    private func recreated(_ path: String, _ failure: WorktreeActions.Failure?) {
        recreating = false
        // The tab has moved on (a session started, another recap): the worktree is back all the same, but this view isn't about it.
        WorktreesModel.shared.refresh()
        guard recap?.worktree == path else { return }
        if let failure {
            recapMessage = failure.message
            return
        }
        recap?.exists = true
        // The folder is typed into the shell: one with a control character in its name is not, and says so.
        if RecapText.isTypeable(path), SessionInput.send("cd -- " + AutomationTemplate.shellQuoted(path), to: surface) {
            recapMessage = nil
        } else {
            recapMessage = "The worktree is back, but the terminal is still where it was: cd to \(path) before starting."
        }
        refreshFolderFacts()
        refreshResume()
        proof.reload()
        assets.folderMayHaveChanged()
    }

    /// Summarize with Claude: only on its button, and only the newest `RecapText.summarizeBatch` sessions that have a transcript
    /// and no summary, one at a time, so one click is never a crowd of Claude processes. The recap says how many are left.
    func summarize() {
        guard let recap, !summarizing, !recap.unsummarized.isEmpty else { return }
        summarizing = true
        recapMessage = nil
        let ids = Array(recap.unsummarized.prefix(RecapText.summarizeBatch)), folder = recap.worktree, surface = surface
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let store = WorkStore()
            let links: [SessionLink] = ids.compactMap { id in
                let cwd = store.record(session: id)?.cwd
                guard let path = BoardEntries.transcript(session: id, folders: [cwd, folder].compactMap { $0 }, projects: Self.projects) else { return nil }
                return SessionLink(surface: surface, sessionID: id, transcriptPath: path, cwd: cwd ?? folder, source: nil)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.requestSummaries(links) } }
        }
    }

    private func requestSummaries(_ links: [SessionLink]) {
        guard recap != nil, summarizing else { return }
        guard !links.isEmpty else {
            summarizing = false
            recapMessage = "These sessions' transcripts are gone, so there is nothing to summarize."
            return
        }
        summaryQueue = links
        summaryProgress = (0, links.count)
        summarizeNext()
    }

    /// Asks for the next summary, or finishes. One request is out at a time.
    private func summarizeNext() {
        guard !summaryQueue.isEmpty else {
            summaryCurrent = nil
            summaryProgress = nil
            summarizing = false
            reloadRecapSoon()
            return
        }
        let link = summaryQueue.removeFirst()
        summaryCurrent = link
        SummaryService.shared.request(link, trigger: .userAsked)
    }

    /// A summary started, finished or failed. The one being waited on moves the queue on; the recap is read again (once,
    /// however many land together).
    private func summaryChanged(_ session: String?) {
        guard let recap, let session, recap.sessions.contains(session) else { return }
        if let link = summaryCurrent, link.sessionID == session {
            switch SummaryService.shared.state(for: link) {
            case .working:
                return
            case .failed(let message, _):
                // The rest would most likely fail the same way: stop here and say so.
                summaryQueue = []
                recapMessage = "Summarizing failed: \(message)"
                summarizeNext()
                return
            case .none, .ready:
                if let progress = summaryProgress { summaryProgress = (progress.done + 1, progress.total) }
                summarizeNext()
                return
            }
        }
        reloadRecapSoon()
    }

    private func reloadRecapSoon() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.reloadRecap() } }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// The recap read again (git, `gh`, files); transcripts that haven't grown aren't read again.
    private func reloadRecap() {
        guard let recap else { return }
        loadRecap(RecapLoader.Input(worktree: recap.worktree, exists: recap.exists, branch: recap.branch, main: recap.main,
                                    sessions: recap.sessions, title: recap.title, pr: recap.pr, older: recap.older))
    }

    func answer(_ answer: PromptAnswer) {
        guard let prompt else { return }
        switch answer {
        case .option, .submit: answeredCall = prompt.call.id
        case .toggle, .note: break
        }
        NeedsYouStudio.shared.answerFromGlance(prompt, answer)
    }

    /// Runs an interactive slash command in the terminal and flips there; the view comes back once the command's row lands.
    func runInteractive(_ command: String) {
        guard let controller else { return }
        returnAfter = (command, timeline.rows.count)
        flippingToTerminal = true
        GlanceMode.set(false, in: controller)
        flippingToTerminal = false
        _ = SessionInput.send("/" + command, to: surface)
    }

    func dismissNewSession() { newSession = false }

    func showTerminal() {
        returnAfter = nil
        if let controller { GlanceMode.set(false, in: controller) }
    }

    // MARK: Session controls

    /// Read from the terminal's screen, so it's what the session runs with now; the transcript lags it.
    func readFooter() {
        // A tab behind others keeps its composer mounted, and has no one to show it to.
        guard controller?.window?.occlusionState.contains(.visible) == true, let next = readScreenFooter(), next != footer else { return }
        footer = next
    }

    private func readScreenFooter() -> SessionFooter? {
        guard let view = (NSApp.delegate as? AppDelegate)?.findSurface(forUUID: surface),
              let text = SurfaceScreen.visibleText(view) else { return nil }
        return SessionFooter.parse(screen: text)
    }

    /// The model's name, once a reply or a `/model` has said it. Claude Code's footer doesn't show it.
    var currentModel: String? { timeline.settings.model.map(UsagePricing.displayName) }
    var currentEffort: String? { footer?.effort ?? timeline.settings.effort }
    var currentEffortTitle: String? {
        currentEffort.map { level in SessionPicks.efforts.first { $0.level == level }?.title ?? level.capitalized }
    }
    var currentMode: PermissionMode? { footer?.mode ?? timeline.settings.permissionMode }

    /// Presses Shift+Tab until the footer shows `target`, a press at a time: no command sets the mode. Stops back where it
    /// began, or with nothing to read, and says so.
    func switchMode(to target: PermissionMode) {
        guard !switchingMode else { return }
        modeFailure = nil
        let start = readScreenFooter()
        guard let start else { modeFailure = target; return }
        footer = start
        switchingMode = true
        Task { [weak self] in
            var presses = 0
            while let self {
                let seen = presses == 0 ? start : self.readScreenFooter()
                if let seen { self.footer = seen }
                switch ModeSwitch.next(target: target, start: start.mode, seen: seen?.mode, presses: presses) {
                case .press:
                    guard let view = (NSApp.delegate as? AppDelegate)?.findSurface(forUUID: self.surface) else {
                        self.switchingMode = false
                        self.modeFailure = target
                        return
                    }
                    SurfaceScreen.pressShiftTab(view)
                    presses += 1
                    try? await Task.sleep(for: Self.modePressWait)
                case .done:
                    self.switchingMode = false
                    return
                case .failed:
                    self.switchingMode = false
                    self.modeFailure = target
                    return
                }
            }
        }
    }

    /// Long enough for Claude Code to redraw its footer after a press.
    private static let modePressWait: Duration = .milliseconds(400)

    // MARK: Phase

    enum Phase {
        /// No Claude in the split: the first message starts it.
        case noClaude
        /// Glance typed `claude`; its session isn't linked yet.
        case starting
        /// A session with no conversation yet (Claude writes its transcript at the first message).
        case ready
        /// The first message is in; nothing to show until the transcript has it.
        case sent
        case timeline
        /// A finished worktree's recap, with a composer that starts a new session on it.
        case recap
    }

    var phase: Phase {
        guard link != nil else { return recap != nil && !starting ? .recap : (starting ? .starting : .noClaude) }
        guard timeline.rows.isEmpty else { return .timeline }
        return queued.isEmpty ? .ready : .sent
    }

    // MARK: Header facts

    /// The session's name: its first prompt on one line, else "Claude".
    var title: String {
        var hadContext = false
        for row in timeline.rows {
            guard case .user(let sent, _) = row.kind else { continue }
            // A recap's context ahead of the prompt is background: the name is what was typed.
            let parts = RecapText.split(sent)
            hadContext = hadContext || parts.context != nil
            let words = parts.typed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if words.isEmpty { continue }
            return words.count > 80 ? String(words.prefix(80)).trimmingCharacters(in: .whitespaces) + "…" : words
        }
        if hadContext { return branch.map { "Session on \($0)" } ?? "New session" }
        return "Claude"
    }

    var folderName: String { FolderLabel.name(forPath: cwd) }

    /// The session's folder, else the split's current directory (before Claude runs).
    var cwd: String? {
        if let cwd = link?.cwd { return cwd }
        // A recap sits in its worktree, or in the main checkout once the worktree was removed.
        if let recap { return recap.exists ? recap.worktree : (recap.main ?? pwd) }
        return pwd
    }

    /// The folder Assets looks in for the branch's and the test runs' media: `cwd`, except that a recap of a removed worktree
    /// has none (its `cwd` is the main checkout). It still shows the captures its records hold.
    var assetsFolder: String? { RecapAssets.scanFolder(cwd: cwd, worktreeGone: link == nil && recap?.exists == false) }

    private var pwd: String? { controller?.surfaceTree.first(where: { $0.id == surface })?.pwd }

    // MARK: Other tabs

    typealias Other = (surface: UUID, title: String, branch: String?, working: Bool, window: NSWindow?)

    /// The other terminal tabs that run a Claude session, for the "All sessions" rail.
    func otherSessions() -> [Other] {
        let rows = Dictionary(TabSidebarModel.shared.rows(for: controller?.window).map { (ObjectIdentifier($0.window), $0) },
                              uniquingKeysWith: { first, _ in first })
        return TerminalController.all.filter { $0 !== controller }.compactMap { c in
            guard let focused = c.focusedSurface, let link = GlanceTerminalHost.shared.sessionLink(for: focused.id) else { return nil }
            let row = c.window.flatMap { rows[ObjectIdentifier($0)] }
            let title = row?.title ?? c.window?.title ?? "Terminal"
            return (focused.id, title, GitHead.branch(inFolder: link.cwd ?? ""), row?.claude == .thinking, c.window)
        }
    }
}
