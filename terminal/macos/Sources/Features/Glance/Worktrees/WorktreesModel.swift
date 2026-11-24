import Combine
import Foundation
import GlanceCore

/// The Worktrees side bar's and pages' data, reloaded every 3 seconds while anything shows it (as the top bar's
/// working changes are), off the main thread.
@MainActor
final class WorktreesModel: ObservableObject {
    static let shared = WorktreesModel()

    @Published private(set) var repos: [RepoTree] = []
    private var timer: Timer?
    private var watchers = 0
    private var loading = false

    func start() {
        watchers += 1
        guard timer == nil else { return }
        refresh()
        // In the common modes, so it also fires while the side bar scrolls.
        let timer = Timer(timeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { WorktreesModel.shared.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .utility).async {
            let repos = WorktreeBook.load()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    WorktreesModel.shared.loading = false
                    if WorktreesModel.shared.repos != repos { WorktreesModel.shared.repos = repos }
                }
            }
        }
    }

    func worktree(_ path: String) -> WorktreeInfo? {
        repos.lazy.flatMap(\.worktrees).first { $0.path == path }
    }
}
