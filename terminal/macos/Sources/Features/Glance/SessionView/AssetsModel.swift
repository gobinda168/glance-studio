import AppKit
import Combine
import GlanceCore
import GlanceKit

/// The Assets section's state (spec §2.5 item 5): the session's captures and what the folder and the PR hold, as one
/// list grouped by origin. Owned by `SessionViewModel`; one per Glance view.
///
/// Two inputs. The scan (the folder's branch and test output, the PR's media) is slow and runs off the main thread; when
/// it may run is decided by `AssetScanGate` (not before the project's setup is read, never two at once, 20 s apart with
/// a trailing scan for what was asked meanwhile). Its results are stamped with the generation and the folder they were
/// taken for and dropped when the tab has moved on. The record (captures) changes often and is cheap: every change merges
/// again at once, with no rescan.
@MainActor
final class AssetsModel: ObservableObject {
    enum Layout: String { case grid, list }

    /// A press on a count in Proof: the section opens and scrolls into view. A new value each time, so a second press on
    /// the same group still counts.
    struct Request: Equatable {
        let serial: Int
        let group: AssetItem.Group
    }

    /// What is only known by reading the file: its length, its size.
    struct Detail: Equatable {
        var duration: Double?
        var bytes: Int64?
    }

    @Published private(set) var items: [AssetItem] = []
    /// One group, or nil for All.
    @Published var filter: AssetItem.Group?
    /// Kept for the life of the panel (this tab), not per scan.
    @Published var layout: Layout = .grid
    @Published private(set) var request: Request?
    @Published private(set) var details: [String: Detail] = [:]
    /// A scan is running: PR media not brought in yet is loading, not failed.
    @Published private(set) var scanning = false

    private weak var session: SessionViewModel?
    private let store = WorkStore()
    private var subscriptions: [AnyCancellable] = []
    nonisolated(unsafe) private var recordObserver: NSObjectProtocol?

    /// What the last scans found, by origin: merged with the captures whenever either changes.
    private var folderFound: [AssetItem] = []
    private var prFound: [AssetItem] = []
    private var record: WorkRecord?
    private var scan: Task<Void, Never>?
    private var trailing: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var gate = AssetScanGate(interval: 20)
    private var panelOpen = false
    /// A recap card is on screen: it shows the first tiles, so it wants the scan too, panel or not.
    private var recapOpen = false
    /// The folder the results are for: `model.cwd`, wherever it comes from (the session's, else the split's own).
    private var folder: String?
    /// A `scanPR` is running, whichever scan started it. Cancelling stops it only after the download in hand, and each
    /// run reads the cache's room once, so a second one must wait: it is asked for again when this one ends.
    private var prInFlight = false
    private var prDeferred = false
    /// Bumped when the tab moves to another session or folder: details read for an earlier one are not this tab's.
    private var epoch = 0
    /// Bumped whenever a scan starts or is cancelled, so only the scan now wanted can store results or end itself.
    private var generation = 0

    // MARK: Following

    /// Follows the proof record and setup. The model keeps no strong reference to the session.
    func attach(_ session: SessionViewModel) {
        self.session = session
        subscriptions = [
            session.proof.$record.sink { [weak self] record in
                MainActor.assumeIsolated { self?.recordChanged(record) }
            },
            // A scan needs the setup (its `assets` patterns): the first one waits for it, and a change rescans.
            Publishers.CombineLatest(session.proof.$setupLoaded, session.proof.$setup).sink { [weak self] loaded, setup in
                MainActor.assumeIsolated { self?.setupChanged(loaded: loaded, patterns: setup.setup?.assets ?? []) }
            },
        ]
        // A clip finished or the explainer moved on: the file is there now, the record may not have been re-read yet.
        recordObserver = NotificationCenter.default.addObserver(forName: .workRecordChanged, object: nil, queue: .main) { [weak self] note in
            let changed = note.userInfo?["session"] as? String
            MainActor.assumeIsolated {
                guard let self, changed == nil || changed == self.session?.proofSession else { return }
                self.record = self.session?.proof.record
                self.merge()
            }
        }
    }

    deinit { if let recordObserver { NotificationCenter.default.removeObserver(recordObserver) } }

    /// The view is gone: no more scans.
    func stop() {
        subscriptions = []
        if let recordObserver { NotificationCenter.default.removeObserver(recordObserver); self.recordObserver = nil }
        cancelScan()
        detailTask?.cancel(); detailTask = nil
    }

    /// The tab follows another session or folder: nothing of the old one may show on the new one, and its scan stops.
    func followChanged(sessionChanged: Bool, folderChanged: Bool) {
        guard sessionChanged || folderChanged else { return }
        epoch += 1
        cancelScan()
        detailTask?.cancel(); detailTask = nil
        folder = nil
        folderFound = []
        prFound = []
        details = [:]
        if sessionChanged { record = nil; filter = nil }
        if !items.isEmpty { items = [] }
    }

    /// The folder `model.cwd` names may have moved (a link arrived, the split's directory changed): clear the old
    /// folder's results and look at the new one.
    func folderMayHaveChanged() {
        let current = session?.assetsFolder
        guard current != folder else { return }
        if folder != nil { followChanged(sessionChanged: false, folderChanged: true) }
        folder = current
        refresh()
    }

    // MARK: Panel

    /// The panel is on screen: scan now (rules of the gate), and again whenever Claude goes idle meanwhile.
    func panelAppeared() {
        panelOpen = true
        refresh()
    }

    /// The panel closed: a scan already running finishes (its results are kept), no new one starts.
    func panelDisappeared() { panelOpen = false }

    /// The same for the recap card's tiles.
    func recapAppeared() {
        recapOpen = true
        refresh()
    }

    func recapDisappeared() { recapOpen = false }

    /// Claude went idle: files may have changed.
    func claudeWentIdle() { if panelOpen || recapOpen { refresh() } }

    // MARK: Showing

    /// Proof's count was pressed: only that group, and the section comes into view.
    func show(group: AssetItem.Group) {
        filter = group
        request = Request(serial: (request?.serial ?? 0) + 1, group: group)
    }

    /// The items the filter shows. A filter on a group that has gone empty shows everything.
    var shown: [AssetItem] {
        guard let filter, items.contains(where: { $0.group == filter }) else { return items }
        return items.filter { $0.group == filter }
    }

    var activeFilter: AssetItem.Group? {
        guard let filter, items.contains(where: { $0.group == filter }) else { return nil }
        return filter
    }

    func count(in group: AssetItem.Group) -> Int { items.filter { $0.group == group }.count }

    func detail(of item: AssetItem) -> Detail? { item.file.flatMap { details[$0.path] } }

    // MARK: Merging

    private func recordChanged(_ next: WorkRecord?) {
        record = next
        merge()
    }

    /// The captures and what the scans found, as one list. Cheap: no scan, no PR.
    private func merge() {
        // Off, the section does nothing: no file is looked at for it.
        guard StudioFeatures.shared.isOn(.commandCenter) else { if !items.isEmpty { items = [] }; return }
        let store = store, id = record?.session
        let merged = AssetGroups.merge(captures: record?.captures ?? [], media: { capture in
            guard let id else { return nil }
            let file = store.mediaFolder(session: id).appendingPathComponent(capture.file)
            return FileManager.default.fileExists(atPath: file.path) ? file : nil
        }, found: folderFound + prFound)
        if merged != items { items = merged }
        loadDetails()
    }

    // MARK: Scanning

    private func setupChanged(loaded: Bool, patterns: [String]) {
        if gate.setup(loaded: loaded, patterns: patterns) { refresh() }
    }

    /// Asks for a scan; the gate says whether it runs now, later (one trailing scan keeps what was asked inside the
    /// window), or when something it waits for arrives.
    func refresh() {
        guard canScan, let cwd = session?.assetsFolder else { return }
        if folder != cwd { folderMayHaveChanged(); return }
        decide(gate.request(now: Date()))
    }

    private var canScan: Bool { StudioFeatures.shared.isOn(.commandCenter) && (panelOpen || recapOpen) && session != nil }

    private func decide(_ decision: AssetScanGate.Decision) {
        switch decision {
        case .start:
            if !startScan() { _ = gate.finished(now: Date()) }
        case .wait(let until):
            trailing?.cancel()
            trailing = Task { [weak self] in
                let delay = until.timeIntervalSinceNow
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                guard !Task.isCancelled, let self else { return }
                self.trailing = nil
                self.decide(self.gate.trailingFired(now: Date()))
            }
        case .none:
            break
        }
    }

    /// False when there is nothing to scan after all.
    private func startScan() -> Bool {
        guard canScan, let session, let cwd = session.assetsFolder, folder == cwd else { return false }
        generation += 1
        let stamp = generation
        scanning = true
        let id = session.proofSession
        let branch = session.branch
        let patterns = gate.currentPatterns
        scan = Task { [weak self] in
            // The folder's media shows as soon as it is found; the PR's downloads can take much longer.
            let info = await Self.offMain { branch.flatMap { ProofPR.find(branch: $0, folder: cwd) } }
            guard !Task.isCancelled else { self?.scanEnded(stamp); return }
            let base = await Self.offMain { RepoBase.find(cwd: cwd, prBase: info?.base.isEmpty == false ? info?.base : nil) }
            guard !Task.isCancelled else { self?.scanEnded(stamp); return }
            let found = await AssetScanner.scanFolder(cwd: cwd, base: base, patterns: patterns)
            guard !Task.isCancelled, self?.accept(folder: found, for: cwd, stamp: stamp) == true else { self?.scanEnded(stamp); return }
            if let info {
                guard let self else { return }
                if self.prInFlight {
                    self.prDeferred = true // the PR part waits for the run in flight; the folder part is already shown
                } else {
                    self.prInFlight = true
                    // The Info from `find`, never one built elsewhere: its `updatedAt` is what keeps the body from being read again.
                    let pr = await AssetScanner.scanPR(info: info, session: id, folder: cwd)
                    self.prFinished()
                    if !Task.isCancelled { self.accept(pr: pr, for: cwd, stamp: stamp) }
                }
            } else if !Task.isCancelled {
                self?.accept(pr: [], for: cwd, stamp: stamp)
            }
            self?.scanEnded(stamp)
        }
        return true
    }

    private func cancelScan() {
        generation += 1
        scan?.cancel()
        scan = nil
        trailing?.cancel()
        trailing = nil
        scanning = false
        gate.reset()
    }

    private func scanEnded(_ stamp: Int) {
        guard stamp == generation else { return }
        scan = nil
        scanning = false
        // Asked for while it ran: one more.
        if gate.finished(now: Date()) { refresh() }
    }

    /// The PR run ended. A scan that had to skip the PR part is run again (after the one now running, if any).
    private func prFinished() {
        prInFlight = false
        if prDeferred { prDeferred = false; refresh() }
    }

    /// False when the results are not for the tab any more: it moved on, or the folder did while the scan ran.
    @discardableResult
    private func accept(folder found: [AssetItem], for cwd: String, stamp: Int) -> Bool {
        guard stamp == generation, isCurrent(cwd) else { return false }
        folderFound = found
        merge()
        return true
    }

    private func accept(pr found: [AssetItem], for cwd: String, stamp: Int) {
        guard stamp == generation, isCurrent(cwd) else { return }
        prFound = found
        merge()
    }

    private func isCurrent(_ cwd: String) -> Bool {
        if session?.assetsFolder == cwd { return true }
        folderMayHaveChanged() // the folder moved during the scan: this result is the old one's
        return false
    }

    /// Off the main thread on a queue of our own: a utility-QoS global queue isn't served while the cooperative pool is
    /// blocked.
    private nonisolated static let blocking = DispatchQueue(label: "dev.glance.assets.model", qos: .userInitiated, attributes: .concurrent)

    private nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            blocking.async { continuation.resume(returning: work()) }
        }
    }

    // MARK: Details

    /// Lengths of the videos and sizes of the files, read off the main thread, one file at a time and published once
    /// per pass (each publish redraws the panel). A file is read once: what could not be read is remembered as unknown.
    private func loadDetails() {
        let wanted = items.compactMap { item -> (path: String, video: Bool, bytes: Int64?)? in
            guard let file = item.file, details[file.path] == nil else { return nil }
            return (file.path, item.kind == .video, item.bytes)
        }
        guard !wanted.isEmpty, detailTask == nil else { return }
        let stamp = epoch
        detailTask = Task { [weak self] in
            var read: [String: Detail] = [:]
            for entry in wanted {
                if Task.isCancelled { return }
                var detail = Detail(duration: nil, bytes: entry.bytes)
                if entry.bytes == nil {
                    detail.bytes = await Self.offMain {
                        (try? FileManager.default.attributesOfItem(atPath: entry.path)[.size] as? NSNumber)?.int64Value
                    }
                }
                if entry.video { detail.duration = await VideoThumbnail.duration(of: URL(fileURLWithPath: entry.path)) }
                read[entry.path] = detail
            }
            guard let self, stamp == self.epoch, !Task.isCancelled else { return }
            self.details.merge(read) { _, new in new }
            self.detailTask = nil
            // Items that arrived while this ran.
            self.loadDetails()
        }
    }
}
