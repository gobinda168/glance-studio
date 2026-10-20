import AppKit
import GlanceCore
import GlanceKit

/// The Review comments inbox's writes (spec 2026-10-07-pr-manager-design.md, "Pages → Review comments"): a reply,
/// which posts at once; Won't fix, which replies "Won't fix." and resolves; Resolve; Unresolve. Each one reads the board
/// again, and an open PR tab's review. It also knows whether Claude Code is installed, for the inbox's Claude buttons.
@MainActor
final class ReviewInboxStore: ObservableObject {
    static let shared = ReviewInboxStore()

    enum Action: Equatable {
        case reply(threadID: String, body: String)
        case wontFix(threadID: String)
        case resolve(threadID: String)
        case unresolve(threadID: String)

        /// Its control, in the busy set and the errors: one of each per thread.
        var name: String {
            switch self {
            case .reply(let id, _): "reply-\(id)"
            case .wontFix(let id): "wontfix-\(id)"
            case .resolve(let id), .unresolve(let id): "resolve-\(id)"
            }
        }
    }

    /// Writes under way, by `Action.name`.
    @Published private(set) var busy: Set<String> = []
    /// The last failed write's message, by `Action.name`, until it's tried again.
    @Published private(set) var errors: [String: String] = [:]
    /// Nil until looked up.
    @Published private(set) var claudeInstalled: Bool?

    private init() {}

    /// Runs a write; `done` runs only when it worked. Then the board reads again (and the pull request's tab, when open).
    func perform(_ action: Action, key: PullRequestStore.Key, then done: (() -> Void)? = nil) {
        let name = action.name
        guard !busy.contains(name) else { return }
        busy.insert(name)
        errors[name] = nil
        let gh = PullRequests.executable()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.run(action, gh: gh)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let store = ReviewInboxStore.shared
                    store.busy.remove(name)
                    switch result {
                    case .success: done?()
                    case .failure(let failure): store.errors[name] = failure.message
                    }
                    PullRequestsModel.shared.load(key.repository, force: true)
                    if PullRequestStore.shared.entries[key] != nil { PullRequestStore.shared.refreshReview(key) }
                }
            }
        }
    }

    nonisolated private static func run(_ action: Action, gh: String?) -> Result<Void, PullRequests.Failure> {
        switch action {
        case .reply(let id, let body):
            return PullRequestStore.mutate(gh, ReviewMutations.reply(threadID: id, body: body))
        case .wontFix(let id):
            return PullRequestStore.mutate(gh, ReviewMutations.reply(threadID: id, body: ReviewInbox.wontFixReply))
                .flatMap { PullRequestStore.mutate(gh, ReviewMutations.resolve(threadID: id)) }
        case .resolve(let id):
            return PullRequestStore.mutate(gh, ReviewMutations.resolve(threadID: id))
        case .unresolve(let id):
            return PullRequestStore.mutate(gh, ReviewMutations.unresolve(threadID: id))
        }
    }

    /// Looks Claude Code up, unless it was found already.
    func checkClaude() {
        guard claudeInstalled != true else { return }
        ClaudeCode.isInstalled { installed in ReviewInboxStore.shared.claudeInstalled = installed }
    }
}
