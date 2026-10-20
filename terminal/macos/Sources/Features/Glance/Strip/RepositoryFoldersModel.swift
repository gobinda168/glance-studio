import AppKit
import Darwin
import GlanceCore
import GlanceKit

/// Which folder on this Mac holds each GitHub repository (spec 2026-10-08-pr-repositories-design.md, "Folders on this
/// Mac"), shared by the side bar and the PR tabs:
/// - the map, saved in Glance's defaults: filled from the folders Glance knows (recent projects, the tab's project) and,
///   once per launch, the folders inside the clone folder, after a check that drops folders that went away;
/// - each looked-up folder's GitHub repositories, for THIS TAB and for a tab's own folder;
/// - Clone… and Choose Folder…, which fill the map so every open tab of the repository gets its folder.
@MainActor
final class RepositoryFoldersModel: ObservableObject {
    static let shared = RepositoryFoldersModel()

    /// A clone under way, or why the last clone or link of a repository failed.
    enum Work: Equatable {
        case cloning
        case cloneFailed(String)
        case linkFailed(String)
    }

    @Published private(set) var map = RepositoryFolders(Prefs.repositoryFolders) {
        didSet { if map != oldValue { Prefs.repositoryFolders = map.folders } }
    }
    /// By repository key (`RepositoryFolders.key`).
    @Published private(set) var work: [String: Work] = [:]
    /// Each looked-up folder's GitHub repositories, in gh's order.
    @Published private(set) var remotes: [String: [String]] = [:]

    /// Folders looked up this launch.
    private var looked: Set<String> = []
    private var launched = false
    private var clones: [String: Process] = [:]

    private init() {}

    func folder(for repository: String) -> String? { map.folder(for: repository) }

    /// The folder for `repository`: `own` (a tab's project) when it is that repository, else the map's.
    func folder(for repository: String, preferring own: String?) -> String? {
        map.folder(for: repository, own: own, ownRepositories: own.flatMap { remotes[$0] } ?? [])
    }

    /// A looked-up folder's repository on GitHub (gh's choice among its remotes); nil while unknown or not on GitHub.
    func repository(ofFolder folder: String) -> String? { remotes[folder]?.first }

    /// Looks up the GitHub remotes of each of `folders` not looked up yet (off the main thread) and records each folder
    /// for its repositories, without moving folders already recorded. The first call also runs the launch check.
    func find(_ folders: [String]) {
        if !launched {
            launched = true
            launchCheck()
        }
        let new = folders.filter { !$0.isEmpty && !looked.contains($0) }
        guard !new.isEmpty else { return }
        looked.formUnion(new)
        DispatchQueue.global(qos: .utility).async {
            let found = new.map { (folder: $0, remotes: Self.remotes(of: $0) ?? []) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { RepositoryFoldersModel.shared.found(found) }
            }
        }
    }

    private func found(_ found: [(folder: String, remotes: [String])]) {
        var map = self.map
        for item in found where !item.remotes.isEmpty {
            remotes[item.folder] = item.remotes
            map.record(item.folder, for: item.remotes, replacing: false)
        }
        self.map = map
    }

    /// Once per launch: drops saved folders that went away or lost the remote, then looks inside the clone folder.
    private func launchCheck() {
        let saved = map
        let cloneFolder = RepositoryFolders.cloneFolder(saved: Prefs.cloneFolder, home: NSHomeDirectory(),
                                                        isDirectory: Self.isDirectory)
        DispatchQueue.global(qos: .utility).async {
            let checked = saved.checked { Self.remotes(of: $0) }
            let inside = cloneFolder.map(Self.clones(in:)) ?? []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let model = RepositoryFoldersModel.shared
                    // Only what the check dropped goes: a folder recorded meanwhile stays.
                    var map = model.map
                    for (key, folder) in saved.folders where checked.folders[key] == nil && map.folders[key] == folder {
                        map.remove(key)
                    }
                    model.map = map
                    model.find(inside)
                }
            }
        }
    }

    // MARK: Clone… and Choose Folder…

    /// Clone…: asks where (the clone folder by default), then `gh repo clone` into a folder with the repository's
    /// name. `work` follows it for the notices; `done` gets the folder once it's cloned.
    func clone(_ repository: String, from window: NSWindow?, then done: ((String) -> Void)? = nil) {
        guard work[RepositoryFolders.key(repository)] != .cloning else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Clone Here"
        panel.message = "Choose where to clone \(repository)."
        panel.directoryURL = URL(fileURLWithPath: Self.startFolder)
        Self.present(panel, on: window) { parent in
            RepositoryFoldersModel.shared.startClone(repository, parent: parent, then: done)
        }
    }

    private func startClone(_ repository: String, parent: String, then done: ((String) -> Void)?) {
        let key = RepositoryFolders.key(repository)
        Prefs.cloneFolder = parent
        let destination = RepositoryFolders.cloneDestination(repository, parent: parent)
        if FileManager.default.fileExists(atPath: destination) {
            work[key] = .cloneFailed(RepositoryFolders.existsMessage(destination))
            return
        }
        guard let gh = PullRequests.executable() else {
            work[key] = .cloneFailed(PullRequests.Failure.notInstalled.message)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = RepositoryFolders.cloneArguments(repository, destination: destination)
        process.environment = GitHubCLI.environment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        let collected = Collected()
        process.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { handle in collected.append(handle.availableData) }
        process.terminationHandler = { process in
            errors.fileHandleForReading.readabilityHandler = nil
            collected.append(errors.fileHandleForReading.readDataToEndOfFile())
            let status = process.terminationStatus
            let cancelled = process.terminationReason == .uncaughtSignal
            let found = status == 0 ? (Self.remotes(of: destination) ?? [repository]) : []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    RepositoryFoldersModel.shared.cloned(repository, into: destination, status: status,
                                                         cancelled: cancelled, errors: collected.data,
                                                         remotes: found, then: done)
                }
            }
        }
        do {
            try process.run()
        } catch {
            work[key] = .cloneFailed("Couldn't start gh: \(error.localizedDescription)")
            return
        }
        clones[key] = process
        work[key] = .cloning
    }

    private func cloned(_ repository: String, into destination: String, status: Int32, cancelled: Bool, errors: Data,
                        remotes found: [String], then done: ((String) -> Void)?) {
        let key = RepositoryFolders.key(repository)
        clones[key] = nil
        if cancelled {
            work[key] = nil
        } else if status != 0 {
            work[key] = .cloneFailed(GitHubCLI.firstLine(errors))
        } else {
            work[key] = nil
            record(destination, remotes: found.isEmpty ? [repository] : found)
            done?(destination)
        }
    }

    /// Cancel: ends gh and the git it started (git takes its half-made folder away).
    func cancelClone(_ repository: String) {
        guard let process = clones[RepositoryFolders.key(repository)], process.isRunning else { return }
        ProcessTree.terminate(process.processIdentifier)
    }

    /// Choose Folder…: an open panel. The folder (its git root) is taken when one of its GitHub remotes is `repository`;
    /// else `work` says what it is. `done` gets the folder once it's taken.
    func chooseFolder(for repository: String, from window: NSWindow?, then done: ((String) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder that holds \(repository)."
        panel.directoryURL = URL(fileURLWithPath: Self.startFolder)
        Self.present(panel, on: window) { folder in
            RepositoryFoldersModel.shared.link(ProjectRoot.find(from: folder), to: repository, then: done)
        }
    }

    private func link(_ folder: String, to repository: String, then done: ((String) -> Void)?) {
        let key = RepositoryFolders.key(repository)
        work[key] = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Self.remotes(of: folder) ?? []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let model = RepositoryFoldersModel.shared
                    if let message = RepositoryFolders.message(RepositoryFolders.choice(for: repository, remotes: found)) {
                        model.work[key] = .linkFailed(message)
                        return
                    }
                    model.record(folder, remotes: found)
                    done?(folder)
                }
            }
        }
    }

    /// Raise without a folder: "owner/name isn't on this Mac" with Clone…, Choose Folder… and Cancel; `done` gets the
    /// folder once there is one.
    func offerFolder(for repository: String, from window: NSWindow?, then done: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = "\(repository) isn't on this Mac"
        alert.informativeText = "Clone it, or choose the folder that holds it, to raise a pull request."
        alert.addButton(withTitle: "Clone…")
        alert.addButton(withTitle: "Choose Folder…")
        alert.addButton(withTitle: "Cancel")
        let answered: (NSApplication.ModalResponse) -> Void = { response in
            // The next turn: the alert's sheet has to be gone before the open panel's comes.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let model = RepositoryFoldersModel.shared
                    switch response {
                    case .alertFirstButtonReturn: model.clone(repository, from: window, then: done)
                    case .alertSecondButtonReturn: model.chooseFolder(for: repository, from: window, then: done)
                    default: break
                    }
                }
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: answered) } else { answered(alert.runModal()) }
    }

    /// A folder Clone… or Choose Folder… gave, for every repository among its remotes.
    private func record(_ folder: String, remotes found: [String]) {
        var map = self.map
        map.record(folder, for: found, replacing: true)
        self.map = map
        remotes[folder] = found
        looked.insert(folder)
    }

    // MARK: Helpers

    /// Where the open panels start: the clone folder, else home.
    private static var startFolder: String {
        RepositoryFolders.cloneFolder(saved: Prefs.cloneFolder, home: NSHomeDirectory(), isDirectory: isDirectory)
            ?? NSHomeDirectory()
    }

    /// Shows `panel` as a sheet on `window` (or on its own); `chosen` gets the folder picked.
    private static func present(_ panel: NSOpenPanel, on window: NSWindow?, chosen: @escaping (String) -> Void) {
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let path = panel.url?.path else { return }
            chosen(path)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    /// A folder's GitHub repositories, in gh's order; nil when it's gone or isn't a git repository.
    nonisolated static func remotes(of folder: String) -> [String]? {
        guard let result = GitHubCLI.execute("/usr/bin/git", ["-C", folder, "remote", "-v"]), result.status == 0 else {
            return nil
        }
        return PullRequests.repositories(remotes: String(decoding: result.output, as: UTF8.self))
    }

    /// The git repositories directly inside `parent`.
    nonisolated private static func clones(in parent: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? []
        return names.filter { !$0.hasPrefix(".") }
            .map { (parent as NSString).appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: ($0 as NSString).appendingPathComponent(".git")) }
            .sorted()
    }

    nonisolated private static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    /// A process's stderr as it arrives, from the pipe's queue.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()

        func append(_ data: Data) {
            lock.lock()
            bytes.append(data)
            lock.unlock()
        }

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return bytes
        }
    }
}

/// Ends a process and the ones it started: gh runs git for a clone, and git doesn't stop when gh does.
enum ProcessTree {
    static func terminate(_ pid: pid_t) {
        for child in children(of: pid) { terminate(child) }
        kill(pid, SIGTERM)
    }

    /// `proc_listchildpids` returns how many pids it wrote (checked on macOS 27, 2026-10-08).
    private static func children(of pid: pid_t) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 64)
        let count = proc_listchildpids(pid, &pids, Int32(MemoryLayout<pid_t>.stride * pids.count))
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count))).filter { $0 > 0 }
    }
}
