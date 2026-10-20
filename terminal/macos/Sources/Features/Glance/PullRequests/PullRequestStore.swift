import AppKit
import GlanceCore
import GlanceKit

/// The PR tabs' data and writes (spec 2026-10-07-pr-manager-design.md, "GitHub"), per pull request: `gh pr view`, its
/// review threads and the repository's merge settings, read off the main thread with the user's own gh login; the
/// issue a number turns out to be; Claude's read and Ask Claude's answers; and every write, after which the page reads
/// again. Shared by every PR tab.
@MainActor
final class PullRequestStore: ObservableObject {
    static let shared = PullRequestStore()

    struct Key: Hashable, Sendable {
        let repository: String
        let number: Int
    }

    /// Claude's read of the pull request at its head commit.
    enum Read: Equatable {
        case idle, reading, unavailable
        case ready(String)
        case failed(String)
    }

    /// Ask Claude about this PR (spec 2026-10-12-pr-sidebar-tabs-design.md, "Ask Claude"): what was asked on the
    /// Overview and answered, and the last question until it's answered.
    struct Ask: Equatable {
        var exchanges: [PullRequestClaude.Exchange] = []
        /// Asked, not answered yet: being answered while `running`, else it failed with `error`.
        var question: String?
        var running = false
        var error: String?
        /// Counts asks, so a stopped one's late answer is dropped.
        var turn = 0
    }

    enum Action: Equatable {
        case merge(PullRequestPage.MergeMethod)
        /// Nil turns auto-merge off.
        case autoMerge(PullRequestPage.MergeMethod?)
        case markReady
        case updateBranch
        case checkout
        case comment(String)
        case close
        case editTitle(String)
        /// The branch it merges into.
        case editBase(String)
        case editBody(String)
        case requestReview(String)
        case addLabel(String)
        case removeLabel(String)
        case linkIssue(Int)
        /// Re-runs a workflow run's failed jobs.
        case rerun(repository: String, run: Int)

        /// Its name in the busy set and the errors: the control it belongs to.
        var name: String {
            switch self {
            case .merge, .autoMerge: "merge"
            case .markReady: "ready"
            case .updateBranch: "update"
            case .checkout: "checkout"
            case .comment: "comment"
            case .close: "close"
            case .editTitle: "title"
            case .editBase: "base"
            case .editBody: "body"
            case .requestReview: "reviewers"
            case .addLabel, .removeLabel: "labels"
            case .linkIssue: "issue"
            case .rerun(_, let run): "rerun-\(run)"
            }
        }
    }

    /// A diff for the Files page.
    enum DiffState: Equatable, Sendable {
        case loading
        case ready([PullRequestDiff.File])
        case failed(String)
    }

    /// What a Checks row unfolds to, read once: a failed job's log, or a check run's title and summary.
    enum CheckDetail: Equatable, Sendable {
        case loading
        case log(PullRequestChecks.Log)
        case output(PullRequestChecks.Output)
        /// gh had nothing to show.
        case empty
        case failed(String)
    }

    struct Entry {
        var page: PullRequestPage.Page?
        /// Set when the number is an issue, not a pull request.
        var issue: PullRequestActions.Issue?
        var extras: ReviewThreads.PageExtras?
        var settings: RepositorySettings.Settings?
        /// gh pr checks' list; nil until it answers (the page's own list shows meanwhile).
        var checks: [PullRequestChecks.Check]?
        var failure: PullRequests.Failure?
        var loading = false
        var loaded: Date?
        /// Writes under way, by `Action.name`.
        var busy: Set<String> = []
        /// The last failed write's message, by `Action.name`, until it's tried again.
        var errors: [String: String] = [:]
        var read: Read = .idle
        var ask = Ask()
    }

    @Published private(set) var entries: [Key: Entry] = [:]
    /// Diffs by `diffKey` (a pull request's at a head commit) or `commitKey` (one commit's).
    @Published private(set) var diffs: [String: DiffState] = [:]
    /// By check run id (an Actions job's id is its check run's). A failed job's log doesn't change.
    @Published private(set) var details: [Int: CheckDetail] = [:]

    /// A read this recent is reused unless a write or Retry forces another.
    private static let freshFor: TimeInterval = 20
    private var reads: [Key: ClaudeOneShot.Run] = [:]
    private var asks: [Key: ClaudeOneShot.Run] = [:]
    /// Claude reads the project's files around the diff, so an answer can take a while.
    private static let askTimeout: TimeInterval = 300
    /// Automations' pr.ci.failed: checks that turn red at a head commit Studio has seen.
    private var ciTracker = CIFailureTracker()

    private init() {}

    func entry(_ key: Key) -> Entry { entries[key] ?? Entry() }

    /// Reads the pull request, unless a read is under way or one finished in the last 20 s (and `force` is off).
    func load(_ key: Key, root: String?, force: Bool = false) {
        let current = entry(key)
        if current.loading { return }
        if !force, let loaded = current.loaded, Date().timeIntervalSince(loaded) < Self.freshFor { return }
        entries[key, default: Entry()].loading = true
        let gh = PullRequests.executable()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.fetch(key, gh: gh)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { PullRequestStore.shared.finish(key, root: root, result) }
            }
        }
    }

    private enum Fetched: Sendable {
        case pullRequest(PullRequestPage.Page, ReviewThreads.PageExtras?, RepositorySettings.Settings?,
                         [PullRequestChecks.Check]?)
        case issue(PullRequestActions.Issue)
    }

    /// The page, its threads, the repository's settings and the checks (four gh calls); or the issue, when gh says the
    /// number isn't a pull request.
    nonisolated private static func fetch(_ key: Key, gh: String?) -> Result<Fetched, PullRequests.Failure> {
        switch GitHubCLI.run(gh, PullRequestPage.arguments(number: key.number, repository: key.repository)) {
        case .failure(let failure):
            if PullRequestActions.isNotAPullRequest(failure),
               case .success(let data) = GitHubCLI.run(gh, PullRequestActions.issueView(key.number, repository: key.repository)),
               let issue = PullRequestActions.parseIssue(data) {
                return .success(.issue(issue))
            }
            return .failure(failure)
        case .success(let data):
            guard let page = PullRequestPage.parse(data) else {
                return .failure(.failed("GitHub sent a pull request Glance can't read"))
            }
            let extras = Self.extras(key, gh: gh)
            let settings = RepositorySettings.arguments(repository: key.repository)
                .flatMap { try? GitHubCLI.run(gh, $0).get() }
                .flatMap(RepositorySettings.parse)
            return .success(.pullRequest(page, extras, settings, checks(key, gh: gh)))
        }
    }

    /// gh pr checks' list: empty when the branch has no checks, nil when gh failed (the last list stays).
    nonisolated private static func checks(_ key: Key, gh: String?) -> [PullRequestChecks.Check]? {
        switch GitHubCLI.run(gh, PullRequestChecks.arguments(number: key.number, repository: key.repository)) {
        case .success(let data): return PullRequestChecks.parse(data)
        case .failure(let failure): return PullRequestChecks.isNoChecks(failure) ? [] : nil
        }
    }

    /// The review's GraphQL page, and the pages after it while GitHub has more (files and threads past 100, at most
    /// 20 pages each).
    nonisolated private static func extras(_ key: Key, gh: String?) -> ReviewThreads.PageExtras? {
        guard var extras = ReviewThreads.pageArguments(repository: key.repository, number: key.number)
            .flatMap({ try? GitHubCLI.run(gh, $0).get() })
            .flatMap(ReviewThreads.parsePage) else { return nil }
        var pages = 0
        while pages < 20, let after = extras.moreFiles,
              let arguments = ReviewThreads.moreArguments(ReviewThreads.moreFilesQuery, repository: key.repository,
                                                          number: key.number, after: after),
              let more = (try? GitHubCLI.run(gh, arguments).get()).flatMap(ReviewThreads.parseMoreFiles) {
            extras.viewed.formUnion(more.viewed)
            extras.moreFiles = more.next
            pages += 1
        }
        pages = 0
        while pages < 20, let after = extras.moreThreads,
              let arguments = ReviewThreads.moreArguments(ReviewThreads.moreThreadsQuery, repository: key.repository,
                                                          number: key.number, after: after),
              let more = (try? GitHubCLI.run(gh, arguments).get()).flatMap(ReviewThreads.parseMoreThreads) {
            extras.threads += more.threads
            extras.moreThreads = more.next
            pages += 1
        }
        return extras
    }

    private func finish(_ key: Key, root: String?, _ result: Result<Fetched, PullRequests.Failure>) {
        var entry = entry(key)
        entry.loading = false
        entry.loaded = Date()
        switch result {
        case .success(.pullRequest(let page, let extras, let settings, let checks)):
            entry.page = page
            entry.issue = nil
            entry.extras = extras ?? entry.extras
            entry.settings = settings ?? entry.settings
            entry.checks = checks ?? entry.checks
            entry.failure = nil
        case .success(.issue(let issue)):
            entry.issue = issue
            entry.failure = nil
        case .failure(let failure):
            // The last page stays on screen; the failure shows above it.
            entry.failure = failure
            if failure == .signedOut { GitHubAccountModel.shared.signedOutSeen() }
        }
        entries[key] = entry
        if case .success(.pullRequest(let page, _, _, let checks?)) = result,
           let event = ciTracker.observe(repo: key.repository, number: key.number, sha: page.headOid,
                                         failing: checks.contains { $0.outcome == .failed }) {
            GlanceEventBus.shared.publish(event)
        }
        if let page = entry.page { startRead(key, root: root, page: page) }
    }

    // MARK: Claude's read

    /// Claude's read at the page's head commit: from the cache, else one read-only `claude -p` over the description,
    /// commits and diff. A new push reads again; a failure waits for Retry.
    private func startRead(_ key: Key, root: String?, page: PullRequestPage.Page) {
        let cacheKey = Self.cacheKey(key, page)
        let cached = PullRequestReadCache.shared.text(cacheKey)
        let busy: Bool
        switch entry(key).read {
        case .reading, .unavailable, .failed: busy = true
        case .idle, .ready: busy = false
        }
        switch AutoClaude.read(auto: Prefs.pullRequestsAutoClaude, cached: cached != nil, busy: busy) {
        case .showCached:
            if let cached, entry(key).read != .ready(cached) { entries[key]?.read = .ready(cached) }
        case .start:
            read(key, root: root, page: page)
        case .offer:
            // Off: a new head's read waits for "Ask Claude to read this PR".
            if entry(key).read != .idle { entries[key]?.read = .idle }
        case .wait:
            break
        }
    }

    func retryRead(_ key: Key, root: String?) {
        guard let page = entry(key).page else { return }
        read(key, root: root, page: page)
    }

    private func read(_ key: Key, root: String?, page: PullRequestPage.Page) {
        entries[key]?.read = .reading
        let gh = PullRequests.executable()
        let cacheKey = Self.cacheKey(key, page)
        DispatchQueue.global(qos: .utility).async {
            let diff = (try? GitHubCLI.run(gh, PullRequestActions.diff(key.number, repository: key.repository)).get())
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let store = PullRequestStore.shared
                    store.reads[key] = ClaudeOneShot.run(
                        arguments: PullRequestClaude.readArguments(),
                        prompt: PullRequestClaude.readPrompt(page, repository: key.repository, diff: diff),
                        folder: root
                    ) { result in
                        store.reads[key] = nil
                        switch result {
                        case .success(let text):
                            PullRequestReadCache.shared.save(text, for: cacheKey)
                            store.entries[key]?.read = .ready(text)
                        case .failure(let failure):
                            store.entries[key]?.read = failure.kind == .notInstalled ? .unavailable : .failed(failure.message)
                        }
                    }
                }
            }
        }
    }

    private static func cacheKey(_ key: Key, _ page: PullRequestPage.Page) -> String {
        "\(key.repository)#\(key.number)@\(page.headOid)"
    }

    // MARK: Ask Claude

    /// A question about the pull request (an empty one asks the general question), answered on its Overview by one
    /// read-only `claude -p` over the pull request as the read gets it and what was asked before: in the project's
    /// folder when it's on this Mac, so Claude can read the files around the diff, else from the diff alone. False when
    /// there's no page yet or an answer is under way.
    @discardableResult
    func ask(_ key: Key, root: String?, question: String) -> Bool {
        let current = entry(key)
        guard let page = current.page, !current.ask.running else { return false }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let asked = trimmed.isEmpty ? PullRequestClaude.generalQuestion : trimmed
        let earlier = current.ask.exchanges
        let turn = current.ask.turn + 1
        entries[key]?.ask.turn = turn
        entries[key]?.ask.question = asked
        entries[key]?.ask.running = true
        entries[key]?.ask.error = nil
        let gh = PullRequests.executable()
        DispatchQueue.global(qos: .userInitiated).async {
            let diff = (try? GitHubCLI.run(gh, PullRequestActions.diff(key.number, repository: key.repository)).get())
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let store = PullRequestStore.shared
                    guard store.asking(key, turn) else { return }
                    store.asks[key] = ClaudeOneShot.run(
                        arguments: PullRequestClaude.askArguments(),
                        prompt: PullRequestClaude.askPrompt(page, repository: key.repository, diff: diff,
                                                            earlier: earlier, question: asked),
                        folder: root,
                        timeout: PullRequestStore.askTimeout
                    ) { result in
                        guard store.asking(key, turn) else { return }
                        store.asks[key] = nil
                        switch result {
                        case .success(let answer):
                            store.entries[key]?.ask.exchanges.append(.init(question: asked, answer: answer))
                            store.entries[key]?.ask.question = nil
                        case .failure(let failure):
                            store.entries[key]?.ask.error = failure.message
                        }
                        store.entries[key]?.ask.running = false
                    }
                }
            }
        }
        return true
    }

    /// The failed question again.
    func retryAsk(_ key: Key, root: String?) {
        guard let question = entry(key).ask.question else { return }
        ask(key, root: root, question: question)
    }

    /// Stop: the answer under way ends, and its question goes.
    func stopAsk(_ key: Key) {
        asks.removeValue(forKey: key)?.cancel()
        entries[key]?.ask.question = nil
        entries[key]?.ask.running = false
        entries[key]?.ask.error = nil
    }

    /// × on the answers: they go, and so does one under way.
    func clearAsks(_ key: Key) {
        stopAsk(key)
        entries[key]?.ask.exchanges = []
    }

    private func asking(_ key: Key, _ turn: Int) -> Bool {
        let ask = entry(key).ask
        return ask.running && ask.turn == turn
    }

    // MARK: Diffs

    /// A pull request's diff at its head commit: a push makes a new one.
    static func diffKey(_ key: Key, head: String) -> String { "\(key.repository)#\(key.number)@\(head)" }

    static func commitKey(_ key: Key, sha: String) -> String { "\(key.repository)@\(sha)" }

    /// Reads the pull request's diff at `head`, unless it's read or being read (a failed read is tried again).
    func loadDiff(_ key: Key, head: String) {
        loadDiff(Self.diffKey(key, head: head), PullRequestDiff.arguments(number: key.number, repository: key.repository))
    }

    /// Reads one commit's diff, unless it's read or being read.
    func loadCommitDiff(_ key: Key, sha: String) {
        loadDiff(Self.commitKey(key, sha: sha), PullRequestDiff.commitArguments(sha: sha, repository: key.repository))
    }

    private func loadDiff(_ id: String, _ arguments: [String]) {
        switch diffs[id] {
        case .loading?, .ready?: return
        case .failed?, nil: break
        }
        diffs[id] = .loading
        let gh = PullRequests.executable()
        DispatchQueue.global(qos: .userInitiated).async {
            let state: DiffState
            switch GitHubCLI.run(gh, arguments) {
            case .success(let data): state = .ready(PullRequestDiff.parse(String(decoding: data, as: UTF8.self)))
            case .failure(let failure): state = .failed(failure.message)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { PullRequestStore.shared.diffs[id] = state }
            }
        }
    }

    // MARK: Checks

    /// Reads what a Checks row unfolds to, unless it's read or being read (a failed read is tried again): a failed
    /// Actions job's log with `gh run view --log-failed`, or a check run's title and summary from the API.
    func loadDetail(_ source: PullRequestChecks.Source) {
        let id: Int
        let arguments: [String]
        switch source {
        case .job(let repository, let run, let job):
            id = job
            arguments = PullRequestChecks.logArguments(repository: repository, run: run, job: job)
        case .checkRun(let repository, let checkRun):
            id = checkRun
            arguments = PullRequestChecks.checkRunArguments(repository: repository, id: checkRun)
        case .elsewhere, .unknown:
            return
        }
        switch details[id] {
        case nil, .failed: break
        case .loading, .log, .output, .empty: return
        }
        details[id] = .loading
        let gh = PullRequests.executable()
        DispatchQueue.global(qos: .userInitiated).async {
            let detail: CheckDetail
            switch GitHubCLI.run(gh, arguments) {
            case .failure(let failure):
                detail = .failed(failure.message)
            case .success(let data):
                if case .job = source {
                    detail = PullRequestChecks.log(String(decoding: data, as: UTF8.self)).map(CheckDetail.log) ?? .empty
                } else {
                    detail = PullRequestChecks.parseOutput(data).map(CheckDetail.output) ?? .empty
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { PullRequestStore.shared.details[id] = detail }
            }
        }
    }

    // MARK: Writes

    /// Runs a write, then reads the page again. Its failure stays under its control until it's tried again; `done`
    /// runs only when it worked.
    func perform(_ action: Action, key: Key, root: String?, then done: (() -> Void)? = nil) {
        let name = action.name
        if action == .checkout, root == nil {
            entries[key, default: Entry()].errors[name] = LocalFolderNotice.needs(key.repository)
            return
        }
        guard !entry(key).busy.contains(name) else { return }
        entries[key, default: Entry()].busy.insert(name)
        entries[key]?.errors[name] = nil
        let command = Self.command(action, key: key, page: entry(key).page, root: root)
        let gh = PullRequests.executable()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = GitHubCLI.run(gh, command.arguments, input: command.input, folder: command.folder)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let store = PullRequestStore.shared
                    store.entries[key]?.busy.remove(name)
                    switch result {
                    case .success: done?()
                    case .failure(let failure): store.entries[key]?.errors[name] = failure.message
                    }
                    store.load(key, root: root, force: true)
                }
            }
        }
    }

    private static func command(_ action: Action, key: Key, page: PullRequestPage.Page?, root: String?)
        -> (arguments: [String], input: Data?, folder: String?) {
        let number = key.number, repository = key.repository
        switch action {
        case .merge(let method):
            return (PullRequestActions.merge(number, repository: repository, method: method), nil, nil)
        case .autoMerge(let method?):
            return (PullRequestActions.merge(number, repository: repository, method: method, auto: true), nil, nil)
        case .autoMerge(nil):
            return (PullRequestActions.disableAutoMerge(number, repository: repository), nil, nil)
        case .markReady:
            return (PullRequestActions.markReady(number, repository: repository), nil, nil)
        case .updateBranch:
            return (PullRequestActions.updateBranch(number, repository: repository), nil, nil)
        case .checkout:
            // In the project folder: gh checks the branch out there, and refuses over uncommitted changes.
            return (PullRequestActions.checkout(number, repository: repository), nil, root)
        case .comment(let text):
            return (PullRequestActions.comment(number, repository: repository), Data(text.utf8), nil)
        case .close:
            return (PullRequestActions.close(number, repository: repository), nil, nil)
        case .editTitle(let title):
            return (PullRequestActions.editTitle(number, repository: repository, title: title), nil, nil)
        case .editBase(let base):
            return (PullRequestActions.editBase(number, repository: repository, base: base), nil, nil)
        case .editBody(let body):
            return (PullRequestActions.editBody(number, repository: repository), Data(body.utf8), nil)
        case .requestReview(let login):
            return (PullRequestActions.editReviewers(number, repository: repository, add: [login]), nil, nil)
        case .addLabel(let label):
            return (PullRequestActions.editLabels(number, repository: repository, add: [label]), nil, nil)
        case .removeLabel(let label):
            return (PullRequestActions.editLabels(number, repository: repository, add: [], remove: [label]), nil, nil)
        case .linkIssue(let issue):
            let body = PullRequestActions.body(page?.body ?? "", closing: issue)
            return (PullRequestActions.editBody(number, repository: repository), Data(body.utf8), nil)
        case .rerun(let runRepository, let run):
            return (PullRequestChecks.rerunArguments(repository: runRepository, run: run), nil, nil)
        }
    }

    // MARK: The review

    /// The review's writes (spec: "GitHub → Writes"): pending comments, replies, resolving, viewed files, Finish review.
    enum ReviewAction: Equatable, Sendable {
        case comment(path: String, line: Int, side: ReviewThreads.Thread.Side, startLine: Int?,
                     startSide: ReviewThreads.Thread.Side?, body: String)
        case edit(commentID: String, body: String)
        case delete(commentID: String)
        case reply(threadID: String, body: String)
        case resolve(threadID: String)
        case unresolve(threadID: String)
        case viewed(path: String, Bool)
        case submit(ReviewMutations.Event, body: String)

        static let commentName = "review-comment"
        static let submitName = "review-submit"

        /// Its name in the busy set and the errors: the control it belongs to.
        var name: String {
            switch self {
            case .comment: Self.commentName
            case .edit(let id, _): "edit-\(id)"
            case .delete(let id): "delete-\(id)"
            case .reply(let id, _): "reply-\(id)"
            case .resolve(let id), .unresolve(let id): "resolve-\(id)"
            case .viewed(let path, _): "viewed-\(path)"
            case .submit: Self.submitName
            }
        }
    }

    /// Runs a review write, then reads the review again. A Viewed tick shows at once and goes back if the write fails.
    /// A failure stays under its control until it's tried again; `done` runs only when the write worked. A comment
    /// starts the viewer's pending review when there's none, and its id is kept at once so the next comment joins it.
    func review(_ action: ReviewAction, key: Key, then done: (() -> Void)? = nil) {
        let name = action.name
        guard !entry(key).busy.contains(name) else { return }
        guard let extras = entry(key).extras else {
            entries[key, default: Entry()].errors[name] = "Glance hasn't read this pull request's review yet."
            return
        }
        entries[key]?.busy.insert(name)
        entries[key]?.errors[name] = nil
        if case .viewed(let path, let viewed) = action { setViewed(key, path, viewed) }
        let gh = PullRequests.executable()
        let pullRequestID = extras.pullRequestID
        let pendingReviewID = extras.pendingReviewID
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.run(action, pullRequestID: pullRequestID, pendingReviewID: pendingReviewID, gh: gh)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let store = PullRequestStore.shared
                    store.entries[key]?.busy.remove(name)
                    switch result {
                    case .success(let startedReview):
                        if let startedReview { store.entries[key]?.extras?.pendingReviewID = startedReview }
                        done?()
                    case .failure(let failure):
                        store.entries[key]?.errors[name] = failure.message
                        if case .viewed(let path, let viewed) = action { store.setViewed(key, path, !viewed) }
                    }
                    store.refreshReview(key)
                }
            }
        }
    }

    private func setViewed(_ key: Key, _ path: String, _ viewed: Bool) {
        if viewed {
            entries[key]?.extras?.viewed.insert(path)
        } else {
            entries[key]?.extras?.viewed.remove(path)
        }
    }

    /// Reads the review again (threads, viewed files, the pending review) without the rest of the page.
    func refreshReview(_ key: Key) {
        let gh = PullRequests.executable()
        DispatchQueue.global(qos: .userInitiated).async {
            let extras = Self.extras(key, gh: gh)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let extras { PullRequestStore.shared.entries[key]?.extras = extras }
                }
            }
        }
    }

    /// A write's gh calls. A comment starts the pending review first when there's none; the started review's id comes
    /// back.
    nonisolated private static func run(_ action: ReviewAction, pullRequestID: String, pendingReviewID: String?,
                                        gh: String?) -> Result<String?, PullRequests.Failure> {
        switch action {
        case .comment(let path, let line, let side, let startLine, let startSide, let body):
            var reviewID = pendingReviewID
            var started: String?
            if reviewID == nil {
                switch GitHubCLI.run(gh, ReviewMutations.startReview(pullRequestID: pullRequestID)) {
                case .failure(let failure):
                    return .failure(failure)
                case .success(let data):
                    guard let id = ReviewMutations.reviewID(from: data) else {
                        return .failure(.failed("GitHub didn't start a review"))
                    }
                    reviewID = id
                    started = id
                }
            }
            guard let reviewID else { return .failure(.failed("GitHub didn't start a review")) }
            return mutate(gh, ReviewMutations.addThread(reviewID: reviewID, path: path, body: body, line: line,
                                                       side: side, startLine: startLine, startSide: startSide))
                .map { _ in started }
        case .edit(let id, let body):
            return mutate(gh, ReviewMutations.editComment(id: id, body: body)).map { _ in nil }
        case .delete(let id):
            return mutate(gh, ReviewMutations.deleteComment(id: id)).map { _ in nil }
        case .reply(let threadID, let body):
            return mutate(gh, ReviewMutations.reply(threadID: threadID, body: body)).map { _ in nil }
        case .resolve(let threadID):
            return mutate(gh, ReviewMutations.resolve(threadID: threadID)).map { _ in nil }
        case .unresolve(let threadID):
            return mutate(gh, ReviewMutations.unresolve(threadID: threadID)).map { _ in nil }
        case .viewed(let path, let viewed):
            return mutate(gh, ReviewMutations.setViewed(pullRequestID: pullRequestID, path: path, viewed: viewed))
                .map { _ in nil }
        case .submit(let event, let body):
            let arguments = pendingReviewID.map { ReviewMutations.submit(reviewID: $0, event: event, body: body) }
                ?? ReviewMutations.review(pullRequestID: pullRequestID, event: event, body: body)
            return mutate(gh, arguments).map { _ in nil }
        }
    }

    /// A mutation through gh. GraphQL answers its errors with a 200, so those are failures too. The inbox writes with it
    /// too.
    nonisolated static func mutate(_ gh: String?, _ arguments: [String]) -> Result<Void, PullRequests.Failure> {
        switch GitHubCLI.run(gh, arguments) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let data):
            if case .failure(let failure) = GitHubCLI.graphQLData(data) { return .failure(failure) }
            return .success(())
        }
    }

    // MARK: Lookups

    /// A read for a menu or a search (labels, people, issues), off the main thread; `done` gets nil when it fails.
    func lookup<T>(_ arguments: [String]?, parse: @escaping @Sendable (Data) -> T?,
                   done: @escaping @MainActor (T?) -> Void) {
        guard let arguments else {
            done(nil)
            return
        }
        let gh = PullRequests.executable()
        DispatchQueue.global(qos: .userInitiated).async {
            let value = (try? GitHubCLI.run(gh, arguments).get()).flatMap(parse)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { done(value) }
            }
        }
    }
}

/// Claude's reads of pull requests, kept on disk by head commit so a read runs once per push
/// (`~/Library/Application Support/Glance/pr-reads.json`, the newest 200).
@MainActor
final class PullRequestReadCache {
    static let shared = PullRequestReadCache()

    private struct Stored: Codable {
        var text: String
        var at: Date
    }

    private var stored: [String: Stored]
    private let file: URL

    private init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Glance")
        file = folder.appendingPathComponent("pr-reads.json")
        stored = (try? JSONDecoder().decode([String: Stored].self, from: Data(contentsOf: file))) ?? [:]
    }

    func text(_ key: String) -> String? { stored[key]?.text }

    func save(_ text: String, for key: String) {
        stored[key] = Stored(text: text, at: Date())
        if stored.count > 200 {
            for old in stored.sorted(by: { $0.value.at < $1.value.at }).prefix(stored.count - 200) {
                stored[old.key] = nil
            }
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(stored).write(to: file, options: .atomic)
    }
}

extension PullRequestStore.Entry {
    /// The pull request's checks: gh pr checks' list once it has answered, else the page's own names and outcomes.
    func shownChecks(_ page: PullRequestPage.Page) -> [PullRequestChecks.Check] {
        checks ?? page.checkList.map { PullRequestChecks.Check($0) }
    }
}
