import AppKit
import Combine
import GlanceCore
import GlanceKit

/// The board's data (spec §5 "Data"): the ledger's sessions via `WorktreesModel`, Studio's links, Needs You's prompts, Work
/// records and each live transcript's tail. No Claude process and no polling of Claude: it runs only while the board or
/// its side bar is on screen, and files are read off the main thread.
@MainActor
final class BoardModel: ObservableObject {
    static let shared = BoardModel()

    @Published private(set) var cards: [BoardCard] = []
    @Published private(set) var entries: [String: BoardEntry] = [:]
    @Published private(set) var loaded = false
    @Published var filter: String?
    @Published var selection: String?
    @Published var reply: String?
    @Published var notice: String?
    /// The reply box's field has the keyboard (the key monitor tells it from any other field by this).
    var replyHasKeyboard = false

    private static let feedTail: UInt64 = 1 << 20
    private static let prSlots = 2
    /// A hung `gh` is stopped after this long and counts as a failed lookup, retried at the normal rate.
    private static let prTimeout: TimeInterval = 30
    /// A structural change (a link, a prompt, a record) shows at once (`queueRebuild`'s default, 0.15 s: a literal, as a
    /// default argument can't read a main-actor constant); a transcript tick moves only a card's "since" and its
    /// place in its lane, so ticks from many sessions are folded into one redraw a second.
    private static let tickDelay: TimeInterval = 1
    /// How often a tab outside git is asked whether its `claude` is still running (a kernel process check, not Claude).
    private static let linkCheckInterval: TimeInterval = 10

    private var watchers = 0
    private var flagOn = StudioFeatures.shared.isOn(.commandCenter)
    private var flagWatch: AnyCancellable?
    /// The board is really running: someone shows it and `Feature.commandCenter` is on.
    private var active = false
    private var subscriptions: [AnyCancellable] = []
    private var observers: [NSObjectProtocol] = []
    private var linkTimer: Timer?
    private var feeds: [String: TimelineFeed] = [:]
    private var live: [String: SessionLive] = [:]
    private var read: [String: ReadFacts] = [:]
    private var linkFacts: [String: LinkOnlyFacts] = [:]
    private var prs: [String: BoardPR] = [:]
    private var prLooked: [String: Date] = [:]
    private var prRunning = 0
    /// The sessions of the latest rebuild, for the next PR lookup when one finishes.
    private var prCandidates: [BoardEntry] = []
    private var reading = false
    private var readAgain = false
    private var checkingLinks = false
    private var pendingRebuild: DispatchWorkItem?
    private var pendingDue = Date.distantFuture

    /// What's read off the main thread for one session.
    struct ReadFacts: Sendable {
        var title: String
        var record: WorkRecord?
        var setup: ProofSetup?
        var transcript: String?
        /// `WorkStore.stamp` taken before the record was read: the record is read again only when it moves.
        var stamp: Date
    }

    private init() {
        // `$enabled` sends the new set before it is stored, so the value it sends is the one to go by.
        flagWatch = StudioFeatures.shared.$enabled.dropFirst().sink { [weak self] enabled in
            guard let self else { return }
            self.flagOn = enabled.contains(.commandCenter)
            self.settle()
        }
    }

    func start() {
        watchers += 1
        settle()
    }

    func stop() {
        watchers = max(0, watchers - 1)
        settle()
    }

    /// Runs while someone shows the board and the feature is on; follows either changing, including the feature going
    /// on or off under a board that is already showing.
    private func settle() {
        let wanted = watchers > 0 && flagOn
        if wanted && !active { activate() }
        if !wanted && active { deactivate() }
    }

    private func activate() {
        active = true
        WorktreesModel.shared.start()
        subscriptions = [WorktreesModel.shared.$repos.dropFirst().sink { [weak self] _ in
            self?.queueRebuild(readFiles: true)
        }]
        let center = NotificationCenter.default
        for name in [Notification.Name.glanceSessionLinksChanged, .glancePromptsChanged, .workRecordChanged] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.queueRebuild(readFiles: name != .glancePromptsChanged) }
            })
        }
        let timer = Timer(timeInterval: Self.linkCheckInterval, repeats: true) { _ in
            MainActor.assumeIsolated { BoardModel.shared.slowCheck() }
        }
        RunLoop.main.add(timer, forMode: .common)
        linkTimer = timer
        queueRebuild(readFiles: true)
    }

    private func deactivate() {
        active = false
        WorktreesModel.shared.stop()
        subscriptions = []
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        linkTimer?.invalidate()
        linkTimer = nil
        pendingRebuild?.cancel()
        pendingRebuild = nil
        pendingDue = .distantFuture
        feeds.values.forEach { $0.stop() }
        feeds = [:]
        live = [:]
    }

    // MARK: Derived

    var visible: [BoardCard] { filter.map { name in cards.filter { $0.project == name } } ?? cards }

    var projects: [(name: String, count: Int)] {
        Dictionary(grouping: cards, by: \.project).map { ($0.key, $0.value.count) }.sorted { $0.name < $1.name }
    }

    func prompt(for card: BoardCard) -> PendingPrompt? {
        guard case .studio(let surface) = card.place else { return nil }
        return prompt(surface: surface, session: card.id)
    }

    /// By split and session: after /clear or a resume in that tab, until the board moves the card, the split's prompt
    /// belongs to another session and isn't this card's to show.
    private func prompt(surface: UUID, session: String) -> PendingPrompt? {
        BoardPromptGuard.prompt(in: NeedsYouStudio.shared.prompts, surface: surface, session: session,
                                linked: GlanceTerminalHost.shared.sessionLink(for: surface)?.sessionID)
    }

    // MARK: Rebuilding

    /// Coalesces the bursts a turn produces (a link, a prompt, a record) into one rebuild. Whatever is already waiting
    /// and due sooner covers a later request.
    private func queueRebuild(readFiles: Bool, after delay: TimeInterval = 0.15) {
        guard active else { return }
        if readFiles { readAgain = true }
        let due = Date().addingTimeInterval(delay)
        if pendingRebuild != nil, pendingDue <= due { return }
        pendingRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingRebuild = nil
                self.pendingDue = .distantFuture
                self.rebuild()
                if self.readAgain {
                    self.readFiles()
                    self.checkLinkOnly()
                }
            }
        }
        pendingRebuild = work
        pendingDue = due
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func rebuild() {
        guard active else { return }
        let waiting = Set(NeedsYouStudio.shared.prompts.compactMap { UUID(uuidString: $0.surface) })
        let merged = BoardEntries.merge(trees: WorktreesModel.shared.repos, links: GlanceTerminalHost.shared.allSessionLinks(),
                                        waiting: waiting, linkOnly: linkFacts)
        let byID = Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0) })
        if entries != byID { entries = byID }
        syncFeeds(merged)
        let next = merged.map(card)
        if cards != next { cards = next }
        // A filter whose project has no sessions any more would leave the board empty with no way to see why. Only once
        // the first read is in: before it the cards are the ledger's and may lack the project.
        if loaded, filter != nil { filter = SessionBoard.keeping(filter: filter, in: next) }
        if let selection, !next.contains(where: { $0.id == selection }) { self.selection = nil }
        prCandidates = merged
        lookUpPRs()
    }

    private func card(_ entry: BoardEntry) -> BoardCard {
        let facts = read[entry.id]
        let pr = entry.branch.flatMap { prs[Self.prKey(repo: entry.repo, branch: $0)] }
        let proofFacts = ProofFacts(uncommitted: false, prChecksFailing: pr?.checks == .failing, prMerged: pr?.merged ?? false)
        let record = facts?.record ?? WorkRecord(session: entry.id, updated: entry.started)
        var waiting: String?
        if case .studio(let surface) = entry.place, let prompt = prompt(surface: surface, session: entry.id) {
            waiting = Self.promptTitle(prompt)
        }
        let session = live[entry.id]
        // The summary's title is a file read, so until the background read has it the name is the task's.
        return BoardCard(id: entry.id, title: facts?.title ?? SessionName.fallback(entry.id, task: entry.task),
                         project: entry.project, repo: entry.repo, branch: entry.branch, worktree: entry.worktree,
                         cwd: facts?.record?.cwd ?? entry.cwd, transcript: entry.transcript ?? facts?.transcript,
                         place: entry.place, state: SessionBoard.state(live: session, waitingTitle: waiting, ended: entry.ended),
                         pill: ProofReview.pill(record, setup: facts?.setup, facts: proofFacts),
                         gaps: ProofReview.gaps(record, setup: facts?.setup, facts: proofFacts),
                         dots: SessionBoard.dots(record: facts?.record, setup: facts?.setup),
                         pending: record.pending.filter { !$0.done }.count,
                         capture: record.captures.filter { $0.kind != .file }.max { $0.at < $1.at }, pr: pr,
                         failing: SessionBoard.failing(facts?.record), mixed: entry.mixed,
                         activity: session?.lastActivity ?? entry.ended ?? record.updated)
    }

    /// The same words as the Glance view's prompt card.
    static func promptTitle(_ prompt: PendingPrompt) -> String {
        if let question = prompt.screen.question, !question.isEmpty { return question }
        switch prompt.kind {
        case .permission: return "Claude wants to use \(prompt.call.name)"
        case .question: return "Claude has a question"
        case .plan: return "Claude's plan is ready"
        }
    }

    // MARK: Transcript tails

    /// One feed per live session with a transcript; ended sessions have none.
    private func syncFeeds(_ merged: [BoardEntry]) {
        let wanted = Dictionary(uniqueKeysWithValues: merged.filter(\.live).compactMap { entry -> (String, String)? in
            guard let path = entry.transcript ?? read[entry.id]?.transcript else { return nil }
            return (entry.id, path)
        })
        for (id, feed) in feeds where wanted[id] == nil {
            feed.stop()
            feeds[id] = nil
            live[id] = nil
        }
        for (id, path) in wanted where feeds[id]?.path != path {
            let feed = feeds[id] ?? TimelineFeed(initialLimit: Self.feedTail)
            feed.onChange = { [weak self] timeline in
                guard let self else { return }
                // A hook writes its record as the tool runs, and the tool's result lands in the transcript about then.
                self.refreshProof([id])
                guard self.live[id] != timeline.live else { return }
                self.live[id] = timeline.live
                self.queueRebuild(readFiles: false, after: Self.tickDelay)
            }
            feed.follow(path, root: nil)
            feeds[id] = feed
        }
    }

    // MARK: Files, off the main thread

    private func readFiles() {
        guard active, !reading else { return }
        reading = true
        readAgain = false
        let wanted = Array(entries.values)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let store = WorkStore()
            let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects").path
            var setups: [String: ProofSetup?] = [:]
            var next: [String: ReadFacts] = [:]
            for entry in wanted {
                let stamp = store.stamp(session: entry.id)
                let record = store.record(session: entry.id)
                let folder = record.flatMap(ProofRecords.folder(of:)) ?? entry.worktree ?? entry.cwd
                var setup: ProofSetup?
                if let folder {
                    if let known = setups[folder] { setup = known }
                    else {
                        setup = ProofSetupFile.load(cwd: folder).setup
                        setups[folder] = setup
                    }
                }
                let folders = [record?.cwd, entry.cwd, entry.worktree].compactMap { $0 }
                next[entry.id] = ReadFacts(title: SessionName.of(entry.id, task: entry.task), record: record, setup: setup,
                                           transcript: entry.transcript ?? BoardEntries.transcript(session: entry.id, folders: folders, projects: projects),
                                           stamp: stamp)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.reading = false
                    guard self.active else { return }
                    self.read = next
                    self.loaded = true
                    self.rebuild()
                    if self.readAgain { self.readFiles() }
                }
            }
        }
    }

    // MARK: Records that changed under us

    private var proofDirty = Set<String>()
    private var refreshingProof = false

    /// What the 10 s timer does: the records of the cards on show (a session waiting on a tool ticks no transcript), and
    /// the tabs outside git.
    private func slowCheck() {
        refreshProof(visible.map(\.id))
        checkLinkOnly()
    }

    /// Hooks and the CLI write records without telling the app. For these sessions, stat the record and summary off the
    /// main thread and read again only those whose time moved (`RecordFreshness`); the proof setup and transcript found
    /// by the last full read are kept. Sessions asked for meanwhile wait for the one in flight.
    private func refreshProof(_ ids: [String]) {
        guard active else { return }
        proofDirty.formUnion(ids)
        guard !refreshingProof else { return }
        let wanted = proofDirty.filter { read[$0] != nil }.sorted()
        proofDirty = []
        guard !wanted.isEmpty else { return }
        refreshingProof = true
        let seen = read.mapValues(\.stamp)
        let tasks = entries.mapValues(\.task)
        let previous = read
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let store = WorkStore()
            let moved = RecordFreshness.changed(sessions: wanted, seen: seen) { store.stamp(session: $0) }
            var fresh: [String: ReadFacts] = [:]
            for id in moved {
                guard var facts = previous[id] else { continue }
                facts.stamp = store.stamp(session: id)
                facts.record = store.record(session: id)
                facts.title = SessionName.of(id, task: tasks[id] ?? nil)
                fresh[id] = facts
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.refreshingProof = false
                    guard self.active else { return }
                    for (id, facts) in fresh where self.read[id] != nil { self.read[id] = facts }
                    if !fresh.isEmpty { self.queueRebuild(readFiles: false) }
                    if !self.proofDirty.isEmpty { self.refreshProof([]) }
                }
            }
        }
    }

    // MARK: Tabs the ledger doesn't know

    /// A tab outside git has a link and nothing else, and its link outlives an exited `claude`. Whether `claude` still
    /// runs there is a process check, and when the transcript began and last changed are file stats: both off the main
    /// thread. Only the splits' foreground processes are read here, as they need the terminal.
    private func checkLinkOnly() {
        guard active, !checkingLinks else { return }
        let links = BoardEntries.linkOnly(trees: WorktreesModel.shared.repos, links: GlanceTerminalHost.shared.allSessionLinks())
        guard !links.isEmpty || !linkFacts.isEmpty else { return }
        checkingLinks = true
        let foreground = GlanceTerminalHost.shared.foregroundPIDs()
        let known = linkFacts
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var next: [String: LinkOnlyFacts] = [:]
            for link in links {
                let running = SessionClaudePID.find(foregroundPID: foreground[link.surface], sessionID: link.sessionID,
                                                    cwd: link.cwd) != nil
                let stats = try? URL(fileURLWithPath: link.transcriptPath)
                    .resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                // A transcript that can't be read keeps the times it had, so the facts don't change on every check.
                let started = stats?.creationDate ?? stats?.contentModificationDate ?? known[link.sessionID]?.started ?? Date()
                let modified = stats?.contentModificationDate ?? known[link.sessionID]?.lastActive ?? started
                // Two tabs on one session: it runs if either does.
                let was = next[link.sessionID]
                next[link.sessionID] = LinkOnlyFacts(running: running || was?.running == true, started: started,
                                                     lastActive: max(modified, was?.lastActive ?? .distantPast))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.checkingLinks = false
                    guard self.active, self.linkFacts != next else { return }
                    self.linkFacts = next
                    self.queueRebuild(readFiles: false)
                }
            }
        }
    }

    // MARK: PRs

    private static func prKey(repo: String?, branch: String) -> String { (repo ?? "") + "\n" + branch }

    /// `gh pr view` for the branches `PRLookups` says are due, at most `prSlots` at a time. Each finished lookup starts
    /// the next one due, so a board that stays quiet still works through every branch. gh that can't answer changes
    /// nothing: the card keeps what it knew, and the branch is asked again at the normal rate.
    private func lookUpPRs() {
        guard active else { return }
        var entries: [String: BoardEntry] = [:]
        var candidates: [PRLookups.Candidate] = []
        for entry in prCandidates where BoardEntries.wantsPR(branch: entry.branch) {
            guard let branch = entry.branch else { continue }
            let key = Self.prKey(repo: entry.repo, branch: branch)
            if entries[key] == nil { entries[key] = entry }
            candidates.append(PRLookups.Candidate(key: key, live: entry.live))
        }
        while prRunning < Self.prSlots, let next = PRLookups.next(candidates, looked: prLooked, now: Date()),
              let entry = entries[next.key], let branch = entry.branch {
            prLooked[next.key] = Date()
            // A single `stat` per looked-up branch.
            guard let folder = [entry.worktree, entry.main, entry.cwd].compactMap({ $0 })
                .first(where: { FileManager.default.fileExists(atPath: $0) }) else { continue }
            prRunning += 1
            let timeout = Self.prTimeout
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let result = ProofPR.lookup(branch: branch, folder: folder, timeout: timeout)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.prRunning -= 1
                        guard self.active else { return }
                        if case .success(let info) = result {
                            let found = info.map { BoardPR(number: $0.number, merged: $0.merged, checks: $0.checks) }
                            if self.prs[next.key] != found {
                                self.prs[next.key] = found
                                self.queueRebuild(readFiles: false)
                            }
                        }
                        self.lookUpPRs()
                    }
                }
            }
        }
    }
}
