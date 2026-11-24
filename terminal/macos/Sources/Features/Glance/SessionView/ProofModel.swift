import AppKit
import Combine
import GlanceCore
import GlanceKit

/// One environment's preview address, or why there isn't one.
struct ProofPreview: Equatable, Identifiable {
    var name: String
    /// The address came from the environment's `urlScript` (a per-PR preview), not a fixed `url`.
    var fromScript: Bool
    var result: Result<String, ProofPR.Failure>
    var id: String { name }
}

/// One Glance view's proof (spec §3): the session's record, the project's setup, its PR. Files are read off the main
/// thread when a tool result arrives or Claude goes idle, and skipped when neither file changed.
@MainActor
final class ProofModel: ObservableObject {
    @Published private(set) var record: WorkRecord?
    @Published private(set) var setup: ProofSetupLoad = .missing
    /// The setup file of the current folder has been read. Until then `.missing` means "not looked at yet", not "absent".
    /// It is set when a read finishes; reads start with the view model, with every transcript change and when the
    /// panel appears, so it can't stay false.
    @Published private(set) var setupLoaded = false
    @Published private(set) var pr: ProofPR.Info?
    /// In the setup's order.
    @Published private(set) var previews: [ProofPreview] = []
    /// An action in flight ("Publishing…").
    @Published private(set) var busy: String?
    /// The last action's result; an error reads as one.
    @Published var message: Notice?
    struct Notice: Equatable {
        var text: String
        var isError: Bool
    }
    @Published private(set) var uncommitted = false

    private weak var session: SessionViewModel?
    private var subscriptions: [AnyCancellable] = []
    nonisolated(unsafe) private var recordObserver: NSObjectProtocol?
    private let store = WorkStore()
    private var loading = false
    private var again = false
    private var stopped = false
    private var stamp: Stamp?
    private var branch: String?
    /// The PR must be looked up again once the setup (its preview scripts) is loaded.
    private var prStale = false
    private var prGeneration = 0
    private var resultsSeen = 0
    private var followUp: DispatchWorkItem?
    private var wasWorking = false
    /// Bumped when the tab moves to another session or folder: an action that finishes after that is not this tab's.
    private var actionEpoch = 0
    private var lastPRLookup: Date?
    /// A PR that was looked up less than this long ago is not looked up again by the panel opening or Claude going idle.
    private static let prLookupInterval: TimeInterval = 20

    /// Follows the session's branch and uncommitted changes. The model keeps no strong reference to the session.
    func attach(_ session: SessionViewModel) {
        self.session = session
        subscriptions = [
            session.$changes.sink { [weak self] summary in
                MainActor.assumeIsolated { self?.setUncommitted((summary?.files ?? 0) > 0) }
            },
            session.$branch.removeDuplicates().sink { [weak self] branch in
                MainActor.assumeIsolated { self?.branchChanged(branch) }
            },
        ]
        // A record changed without a tool call or a transcript line (a clip finished, Make explainer moved on): the
        // transcript doesn't move then, so the record is read on this signal.
        if let old = recordObserver { NotificationCenter.default.removeObserver(old) }
        recordObserver = NotificationCenter.default.addObserver(forName: .workRecordChanged, object: nil, queue: .main) { [weak self] note in
            let changed = note.userInfo?["session"] as? String
            MainActor.assumeIsolated {
                guard let self, !self.stopped, changed == nil || changed == self.session?.proofSession else { return }
                self.reload()
            }
        }
    }

    deinit { if let recordObserver { NotificationCenter.default.removeObserver(recordObserver) } }

    /// The tab now follows another session or folder: nothing of the old one may show on the new one. Called before the
    /// new link is read, so the pill never carries one session's record, or one repository's PR, over to another.
    func followChanged(sessionChanged: Bool, folderChanged: Bool) {
        if sessionChanged {
            if record != nil { record = nil }
        }
        if sessionChanged || folderChanged {
            actionEpoch += 1
            busy = nil
            message = nil
            dropPR()
        }
        // The setup file and the working changes belong to the folder.
        if folderChanged {
            stamp = nil // read the folder's files again whatever they look like
            setupLoaded = false
            if setup != .missing { setup = .missing }
            if uncommitted { uncommitted = false }
        }
    }

    /// Forgets the PR and its previews, drops a lookup still in flight, and has the next read look it up again.
    private func dropPR() {
        prGeneration += 1
        lastPRLookup = nil
        if pr != nil { pr = nil }
        if !previews.isEmpty { previews = [] }
        prStale = true
    }

    /// The view is gone: no more reads, lookups or timers.
    func stop() {
        stopped = true
        subscriptions = []
        if let recordObserver { NotificationCenter.default.removeObserver(recordObserver); self.recordObserver = nil }
        followUp?.cancel()
        followUp = nil
    }

    // MARK: Derived

    var facts: ProofFacts {
        ProofFacts(uncommitted: uncommitted, prChecksFailing: pr?.checksFailing ?? false, prMerged: pr?.merged ?? false)
    }
    var pill: ProofPill { ProofReview.pill(record ?? Self.empty, setup: setup.setup, facts: facts) }
    var gaps: [ProofGap] { ProofReview.gaps(record ?? Self.empty, setup: setup.setup, facts: facts) }
    private static let empty = WorkRecord(session: "", updated: .distantPast)

    func mediaURL(_ capture: ProofCapture) -> URL {
        store.mediaFolder(session: record?.session ?? "").appendingPathComponent(capture.file)
    }

    func checkMatch(for command: String) -> ProofCheckMatch? {
        setup.setup.flatMap { ProofMatcher.check(for: command, in: $0) }
    }

    /// The run Glance recorded for this tool call (a run's id is its tool call's id), never by command text.
    func checkRun(forTool id: String) -> ProofCheckRun? { record?.checks.first { $0.id == id } }
    var hasPassingRun: Bool { record?.checks.contains(where: \.ok) == true }
    var setupExists: Bool { setup.setup != nil }

    // MARK: Reading

    /// The transcript moved. Tool calls write the transcript and every proof write follows one, so the record is read
    /// when a result arrives (and again a moment later: the hook that records a check may land after the transcript
    /// line) and whenever Claude is idle, not on every streamed chunk.
    func timelineChanged(_ timeline: SessionTimeline) {
        var results = 0
        for row in timeline.rows {
            if case .tool(_, _, let result, _) = row.kind, result != nil { results += 1 }
        }
        let arrived = results != resultsSeen
        resultsSeen = results
        if arrived || !timeline.live.working { reload() }
        if arrived { reloadSoon() }
        // Claude just went idle: a PR opened meanwhile, or CI turning red, shows up.
        let working = timeline.live.working
        if wasWorking && !working { refreshPRIfStale() }
        wasWorking = working
    }

    private func reloadSoon() {
        followUp?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        followUp = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    /// Re-reads the record and the setup off the main thread; coalesces calls that arrive during a read. A file whose
    /// modification time and size are unchanged is not decoded again.
    func reload() {
        guard !stopped, let session else { return }
        guard !loading else { again = true; return }
        let id = session.proofSession
        let cwd = session.cwd
        loading = true
        let store = store, previous = stamp
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let loaded = Self.read(store: store, id: id, cwd: cwd, previous: previous)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishReading(loaded, id: id, cwd: cwd) }
            }
        }
    }

    private func finishReading(_ loaded: Loaded, id: String?, cwd: String?) {
        loading = false
        guard !stopped else { return }
        // The tab moved to another session or folder while this was read: read again for the new one.
        guard id == session?.proofSession, cwd == session?.cwd else { again = false; reload(); return }
        if !setupLoaded { setupLoaded = true }
        // Another folder is another repository: its PR is not this one's (the branch name can be the same).
        if let old = stamp, old.cwd != cwd { dropPR() }
        stamp = loaded.stamp
        var setupChanged = false
        if case .new(let next) = loaded.record, record != next { record = next }
        if case .new(let next) = loaded.setup, setup != next { setup = next; setupChanged = true }
        if again { again = false; reload() }
        if prStale || setupChanged { prStale = false; refreshPR() }
    }

    private struct FileStamp: Equatable, Sendable {
        var modified: Date
        var size: Int
    }
    private struct Stamp: Equatable, Sendable {
        var session: String?
        var cwd: String?
        var record: FileStamp?
        var setupRoot: String?
        var setup: FileStamp?
    }
    private enum Part<T: Sendable>: Sendable { case same, new(T) }
    private struct Loaded: Sendable {
        var stamp: Stamp
        var record: Part<WorkRecord?> = .same
        var setup: Part<ProofSetupLoad> = .same
    }

    nonisolated private static func fileStamp(_ path: String) -> FileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return FileStamp(modified: modified, size: (attributes[.size] as? NSNumber)?.intValue ?? 0)
    }

    nonisolated private static func read(store: WorkStore, id: String?, cwd: String?, previous: Stamp?) -> Loaded {
        let recordFile = id.flatMap { WorkStore.isSessionID($0) ? store.sessionFolder($0).appendingPathComponent("record.json").path : nil }
        let root = cwd.flatMap { ProofSetupFile.root(from: $0) }
        let stamp = Stamp(session: id, cwd: cwd, record: recordFile.flatMap(fileStamp), setupRoot: root,
                          setup: root.flatMap { fileStamp($0 + "/" + ProofSetupFile.relativePath) })
        let sameSession = previous?.session == id && previous?.cwd == cwd
        var loaded = Loaded(stamp: stamp)
        if !(sameSession && previous?.record == stamp.record) { loaded.record = .new(id.flatMap { store.record(session: $0) }) }
        if !(sameSession && previous?.setupRoot == root && previous?.setup == stamp.setup) {
            loaded.setup = .new(cwd.map { ProofSetupFile.load(cwd: $0) } ?? .missing)
        }
        return loaded
    }

    // MARK: Uncommitted, branch, PR

    private func setUncommitted(_ value: Bool) { if uncommitted != value { uncommitted = value } }

    private func branchChanged(_ next: String?) {
        guard !stopped, next != branch else { return }
        branch = next
        dropPR()
        reload()
    }

    /// The PR for the session's branch and the setup's environment addresses. gh that can't answer (signed out, not
    /// installed) changes nothing: the pill simply has no PR facts.
    func refreshPR() {
        guard !stopped, StudioFeatures.shared.isOn(.commandCenter) else { return }
        lastPRLookup = Date()
        prGeneration += 1
        let generation = prGeneration
        guard let cwd = session?.cwd, let branch else {
            if pr != nil { pr = nil }
            if !previews.isEmpty { previews = [] }
            return
        }
        let (setup, worktree, known) = (setup, record?.worktree, pr)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let looked = ProofPR.lookup(branch: branch, folder: cwd)
            var info = known, answered = false
            if case .success(let found) = looked { info = found; answered = true }
            let previews = Self.previewList(setup: setup, info: info, branch: branch, worktree: worktree)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.stopped, self.prGeneration == generation else { return }
                    if answered, self.pr != info { self.pr = info }
                    if self.previews != previews { self.previews = previews }
                }
            }
        }
    }

    /// `refreshPR`, unless the PR was looked up a moment ago (the panel opening, Claude going idle).
    func refreshPRIfStale() {
        guard setup.setup != nil else { return }
        if let last = lastPRLookup, Date().timeIntervalSince(last) < Self.prLookupInterval { return }
        refreshPR()
    }

    /// Shared with the pull request page's Proof card.
    nonisolated static func previewList(setup: ProofSetupLoad, info: ProofPR.Info?, branch: String,
                                        worktree: String?) -> [ProofPreview] {
        guard let s = setup.setup, let root = setup.root else { return [] }
        var out: [ProofPreview] = []
        for env in s.environments {
            let fixed = !(env.url ?? "").isEmpty
            guard fixed || env.urlScript != nil else { continue }
            if !fixed, info == nil { continue } // a preview made by a script needs its PR
            let result = ProofPR.previewURL(env: env, info: info, root: root, branch: branch, worktree: worktree)
            out.append(ProofPreview(name: env.name, fromScript: !fixed, result: result))
        }
        return out
    }

    // MARK: Actions

    /// The summary written into a PR description: the markdown with the per-PR previews (an environment whose address
    /// came from its script; a fixed `url` is already in the setup). The panel and the PR page's card both publish this.
    nonisolated static func summary(_ record: WorkRecord, setup: ProofSetup?, facts: ProofFacts,
                                    previews: [ProofPreview]) -> String {
        let urls = previews.compactMap { preview -> (environment: String, url: String)? in
            guard preview.fromScript, case .success(let url) = preview.result else { return nil }
            return (preview.name, url)
        }
        return ProofSummary.markdown(record, setup: setup, facts: facts, previews: urls)
    }

    func publish() {
        guard let pr, let record, let cwd = session?.cwd, busy == nil else { return }
        let summary = Self.summary(record, setup: setup.setup, facts: facts, previews: previews)
        run("Publishing…", { ProofPR.publish(summary: summary, info: pr, folder: cwd) }, done: "Summary written to #\(pr.number)'s description")
    }

    /// Merges the PR. The panel has already asked the user (it names the PR and its base); this only refuses what must
    /// not be merged: the verdict has to be Ready and the PR open.
    func merge() {
        guard let pr, pr.state == "OPEN", pill == .ready, let cwd = session?.cwd, busy == nil else { return }
        run("Merging…", { ProofPR.merge(info: pr, folder: cwd) }, done: "Merged #\(pr.number)")
    }

    private func run(_ label: String, _ work: @escaping @Sendable () -> Result<Void, ProofPR.Failure>, done: String) {
        busy = label
        message = nil
        let epoch = actionEpoch
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = work()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // The tab has moved to another session or folder since: this result is not for it.
                    guard let self, self.actionEpoch == epoch else { return }
                    self.busy = nil
                    switch result {
                    case .success: self.message = Notice(text: done, isError: false); self.refreshPR()
                    case .failure(let failure): self.message = Notice(text: failure.message, isError: true)
                    }
                }
            }
        }
    }

    // MARK: Make explainer

    /// Starts Make explainer for this session (the panel's button and Retry). The run belongs to `ExplainerRun`; this
    /// only says what it is made from. The PR's base, when there is one, is what the diff is taken against.
    func makeExplainer() {
        guard StudioFeatures.shared.isOn(.commandCenter), let id = session?.link?.sessionID, let cwd = session?.cwd else { return }
        var source = record ?? WorkRecord(session: id, updated: Date())
        if source.cwd == nil { source.cwd = cwd }
        let base = pr?.base
        ExplainerRun.shared.start(session: id, record: source, setup: setup.setup, cwd: cwd,
                                  prBase: base?.isEmpty == false ? base : nil)
    }

    // MARK: Asking Claude

    /// What the buttons send to Claude (the glance-proof-setup skill does the work).
    enum Prompt {
        static let setUp = "Set up Glance proof of work for this project (use the glance-proof-setup skill)."
        /// The first issue, with its line.
        static func fix(_ issue: ProofSetupIssue) -> String {
            let what = issue.line.map { "line \($0): \(issue.message)" } ?? issue.message
            return "Fix .glance/proof.json: \(what) (use the glance-proof-setup skill)."
        }
        /// A draft for the composer: the user says what changes.
        static let update = "Update this project's Glance proof setup (use the glance-proof-setup skill): "
    }
}
