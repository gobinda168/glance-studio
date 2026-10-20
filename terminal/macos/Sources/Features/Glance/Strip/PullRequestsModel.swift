import AppKit
import GlanceCore
import GlanceKit

/// The Pull Requests side bar's data, shared by every window (spec 2026-10-08-pr-repositories-design.md). Each side bar
/// asks for its repository. It holds:
/// - each repository's lists with its open pull requests' review threads (one query: the rows' counts, the Review
///   comments row and the inbox), read off the main thread with the GitHub CLI and the user's own login;
/// - the repository picked in the picker, for every window and across launches, and the picker's RECENT;
/// - the tab shown, likewise.
@MainActor
final class PullRequestsModel: ObservableObject {
    static let shared = PullRequestsModel()

    /// A load this recent is reused unless the user asks for a refresh: every tab window showing the side bar asks.
    private static let freshFor: TimeInterval = 45

    /// One repository's lists, or why there are none. The last lists stay while a refresh runs and after a failed one.
    struct Entry {
        var board: PullRequests.Board?
        /// The open pull requests' threads and the viewer. The last ones stay when a read of them fails.
        var reviews: ReviewThreads.BoardThreads?
        var failure: PullRequests.Failure?
        var loading = false
        var loaded: Date?
    }

    /// By repository key (`RepositoryFolders.key`).
    @Published private(set) var entries: [String: Entry] = [:]
    /// How many pull requests wait on you in the repository shown last: the strip's badge.
    @Published private(set) var badge = 0
    /// The side bar's tab (To review, Yours or Merged), in every window and across launches.
    @Published var tab: PullRequests.List = Prefs.pullRequestsTab {
        didSet { Prefs.pullRequestsTab = tab }
    }
    /// The repository picked in the picker, for every window and across launches; nil until one is.
    @Published private(set) var picked: String? = Prefs.pullRequestsRepository
    /// The picker's RECENT, newest first.
    @Published private(set) var recent: [String] = Prefs.pullRequestsRecent

    /// The key of the repository shown last, whose waiting count is the badge.
    private var shown: String?
    private var loadAgain: Set<String> = []

    private init() {}

    /// Picks `repository` for every window, saved for the next launch, and first in RECENT.
    func pick(_ repository: String) {
        picked = repository
        Prefs.pullRequestsRepository = repository
        guard repository != PullRequests.allRepositories else { return }
        recent = RepositoryPicker.recent(after: repository, in: recent)
        Prefs.pullRequestsRecent = recent
    }

    /// Signed out: no lists, no badge.
    func clear() {
        entries = [:]
        badge = 0
        loadAgain = []
    }

    func entry(for repository: String) -> Entry {
        entries[RepositoryFolders.key(repository)] ?? Entry()
    }

    /// Loads `repository`'s lists and their thread counts, unless they're fresh (and `force` is off) or a load is under
    /// way (then once more after it).
    func load(_ repository: String, force: Bool = false) {
        let key = RepositoryFolders.key(repository)
        if shown != key {
            shown = key
            badge = entries[key]?.board?.waitingOnYou.count ?? 0
        }
        let entry = entries[key] ?? Entry()
        if entry.loading {
            if force { loadAgain.insert(key) }
            return
        }
        if !force, let loaded = entry.loaded, Date().timeIntervalSince(loaded) < Self.freshFor { return }
        entries[key, default: Entry()].loading = true
        DispatchQueue.global(qos: .utility).async {
            let gh = PullRequests.executable()
            let all = repository == PullRequests.allRepositories
            let result = all ? PullRequests.accountBoard(gh: gh) : PullRequests.board(repository: repository, gh: gh)
            // Threads are read per repository: none for All repositories (no chips, no Review comments row).
            let reviews = all ? nil : (try? result.get()).flatMap { Self.reviews(of: $0, gh: gh) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { PullRequestsModel.shared.finish(repository, result, reviews: reviews) }
            }
        }
    }

    /// Every open pull request's threads, whole, in one GraphQL query. Nil when it fails.
    nonisolated private static func reviews(of board: PullRequests.Board, gh: String?) -> ReviewThreads.BoardThreads? {
        let numbers = Set((board.waitingOnYou + board.yours).map(\.number)).sorted()
        guard let arguments = ReviewThreads.boardArguments(repository: board.repository, numbers: numbers) else {
            return ReviewThreads.BoardThreads(viewer: "", threads: [:]) // no open pull requests
        }
        return (try? GitHubCLI.run(gh, arguments).get()).flatMap(ReviewThreads.parseBoard)
    }

    private func finish(_ repository: String, _ result: Result<PullRequests.Board, PullRequests.Failure>,
                        reviews: ReviewThreads.BoardThreads?) {
        let key = RepositoryFolders.key(repository)
        var entry = entries[key] ?? Entry()
        entry.loading = false
        entry.loaded = Date()
        switch result {
        case .success(let board):
            entry.board = board
            entry.reviews = reviews ?? entry.reviews
            entry.failure = nil
        case .failure(let failure):
            entry.failure = failure
            switch failure {
            case .failed: break // offline or a hiccup: keep showing the last lists
            case .signedOut:
                entry.board = nil
                entry.reviews = nil
                GitHubAccountModel.shared.signedOutSeen()
            case .notInstalled, .notGitHub:
                entry.board = nil
                entry.reviews = nil
            }
        }
        entries[key] = entry
        if key == shown { badge = entry.board?.waitingOnYou.count ?? 0 }
        if loadAgain.remove(key) != nil { load(repository, force: true) }
    }
}
