import AppKit
import GlanceCore
import GlanceKit

/// Claude's fixes and applied suggestions (spec 2026-10-07-pr-manager-design.md, "Claude → Fixes"), one at a time per
/// project:
/// 1. A snapshot of the working tree (nothing is staged or committed).
/// 2. Either the threads go to the project's Claude (its terminal session, else Glance's headless one), told to change
///    the files only; or the suggestion is written into its file.
/// 3. When the turn ends, or on Stop, what changed since the snapshot is the fix, ready to accept or reject.
/// 4. Accept commits only those files, pushes, and replies "Fixed in abc1234" and resolves. Reject puts them back.
@MainActor
final class FixJobs: ObservableObject {
    static let shared = FixJobs()

    enum State: Equatable {
        /// The snapshot is being taken, or the changes read.
        case preparing
        /// Claude's turn, and what it's doing when its transcript says.
        case fixing(activity: String?)
        case ready(FixPatch.Fix)
        case noChanges
        case committing
        /// Reject is putting the files back.
        case rejecting
        case pushFailed(sha: String, message: String)
        case done(sha: String, note: String?)
        /// Put back, with the files kept because they changed again after the fix was ready.
        case rejected(kept: [String])
        case failed(String)
    }

    struct Job: Equatable {
        let root: String
        let key: PullRequestStore.Key
        let threadIDs: [String]
        /// An applied suggestion, not Claude's work.
        let isSuggestion: Bool
        /// The commit's message.
        let message: String
        var state: State
        var replyAndResolve = true
        /// The last Accept or Reject that failed, shown with Fix ready.
        var error: String?
        var route: ChatRoute?
        /// Claude's transcript for this turn, once its prompt is seen.
        var transcript: String?
        /// The snapshot before the fix.
        var before: String?

        /// Waiting on Claude or on the user: another fix in this project waits too.
        var isBusy: Bool {
            switch state {
            case .preparing, .fixing, .ready, .committing, .rejecting, .pushFailed: true
            case .noChanges, .done, .rejected, .failed: false
            }
        }
    }

    /// By project root.
    @Published private(set) var jobs: [String: Job] = [:]
    private var poll: Timer?

    private init() {}

    func job(for threadID: String) -> Job? { jobs.values.first { $0.threadIDs.contains(threadID) } }

    func isBusy(root: String) -> Bool { jobs[root]?.isBusy ?? false }

    // MARK: Starting

    /// Fix with Claude: `threads` of `page`, in `root` (on the pull request's branch).
    func fix(_ threads: [ReviewThreads.Thread], page: PullRequestPage.Page, key: PullRequestStore.Key, root: String,
             window: NSWindow?) {
        fix(threads, number: page.number, title: page.title, key: key, root: root, window: window)
    }

    /// Fix with Claude from the inbox, which knows the pull request by its list row: its number and title.
    func fix(_ threads: [ReviewThreads.Thread], number: Int, title: String, key: PullRequestStore.Key, root: String,
             window: NSWindow?) {
        guard !isBusy(root: root), !threads.isEmpty else { return }
        let prompt = PullRequestClaude.fixPrompt(threads, number: number, title: title, repository: key.repository)
        jobs[root] = Job(root: root, key: key, threadIDs: threads.map(\.id), isSuggestion: false,
                         message: FixPatch.commitMessage(threads), state: .preparing)
        AgentsActivity.shared.set("fix:" + root, running: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let before = FixPatch.snapshot(root: root)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { FixJobs.shared.send(prompt, before: before, root: root, window: window) }
            }
        }
    }

    private func send(_ prompt: String, before: Result<String, PullRequests.Failure>, root: String, window: NSWindow?) {
        guard jobs[root]?.state == .preparing else { return }
        switch before {
        case .failure(let failure):
            finish(root, .failed(failure.message))
        case .success(let tree):
            jobs[root]?.before = tree
            jobs[root]?.state = .fixing(activity: nil)
            // Claude Code missing fails the headless run, perhaps before this call returns (`chat` hears it).
            guard let route = GlanceTerminalHost.shared.sendToProjectClaude(prompt, root: root, showIn: window) else {
                finish(root, .failed("Claude is answering in this project's Glance chat. Try again when it's done."))
                return
            }
            jobs[root]?.route = route
            startPolling()
        }
    }

    /// Apply suggestion: `lines` in place of the thread's lines, when they still read `original`; then the same Fix
    /// ready, Accept and Reject.
    func applySuggestion(_ thread: ReviewThreads.Thread, lines: [String], original: [String],
                         key: PullRequestStore.Key, root: String) {
        guard !isBusy(root: root), let end = thread.line else { return }
        let start = thread.startLine ?? end
        let path = thread.path
        jobs[root] = Job(root: root, key: key, threadIDs: [thread.id], isSuggestion: true,
                         message: FixPatch.suggestionMessage(thread), state: .preparing)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.apply(lines, original: original, start: start, end: end, path: path, root: root)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { FixJobs.shared.collected(root, result) }
            }
        }
    }

    /// Writes the suggestion in place: the file keeps its permissions (a script stays executable).
    nonisolated private static func apply(_ lines: [String], original: [String], start: Int, end: Int, path: String,
                                          root: String) -> Result<FixPatch.Fix?, PullRequests.Failure> {
        let before: String
        switch FixPatch.snapshot(root: root) {
        case .failure(let failure): return .failure(failure)
        case .success(let tree): before = tree
        }
        let file = (root as NSString).appendingPathComponent(path)
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
            return .failure(.failed("Couldn't read \(path)."))
        }
        guard let changed = FixPatch.applying(lines, to: text, start: start, end: end, original: original) else {
            return .failure(.failed("\(path) changed since the review: apply the suggestion by hand."))
        }
        do {
            try changed.write(toFile: file, atomically: false, encoding: .utf8)
        } catch {
            return .failure(.failed("Couldn't write \(path)."))
        }
        return FixPatch.collect(root: root, before: before)
    }

    // MARK: Claude's turn

    /// A transcript event: the first prompt in the project after the fix went out is Claude's turn, and that
    /// transcript's end is the fix's. Esc typed in the terminal writes "[Request interrupted by user]" (a second
    /// prompt) and no end, so a second prompt ends the fix too.
    func transcript(_ event: TranscriptWatcher.Event) {
        for (root, job) in jobs {
            guard case .fixing = job.state, SessionMatch.matches(sessionCwd: event.cwd, surfacePwd: root) else { continue }
            switch event.kind {
            case .prompt:
                if job.transcript == nil {
                    jobs[root]?.transcript = event.file
                } else if event.file == job.transcript {
                    endSoon(root)
                }
            case .done:
                if event.file == job.transcript { finishTurn(root) }
            }
        }
    }

    /// The headless session's run: its end (a Stop included) is the fix's, and a failure (Claude Code missing, say)
    /// fails it. Until the route is known it can only be the headless one: a terminal never reports here.
    func chat(root: String, event: ChatSessions.Event) {
        guard case .fixing? = jobs[root]?.state else { return }
        if case .terminal? = jobs[root]?.route { return }
        switch event {
        case .started: break
        case .finished: finishTurn(root)
        case .failed(let message): finish(root, .failed(message))
        }
    }

    /// Stop: ends Claude's turn, and whatever it changed so far is the fix.
    func stop(root: String) {
        guard case .fixing? = jobs[root]?.state else { return }
        GlanceTerminalHost.shared.stopProjectClaude(root: root)
        endSoon(root)
    }

    /// An interrupted turn writes no end: the changes are read a second later, once Claude has let go of the files.
    private func endSoon(_ root: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated { FixJobs.shared.finishTurn(root) }
        }
    }

    /// Claude's turn ended: what changed since the snapshot is the fix.
    private func finishTurn(_ root: String) {
        guard case .fixing? = jobs[root]?.state, let before = jobs[root]?.before else { return }
        jobs[root]?.state = .preparing
        DispatchQueue.global(qos: .userInitiated).async {
            let result = FixPatch.collect(root: root, before: before)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { FixJobs.shared.collected(root, result) }
            }
        }
    }

    private func collected(_ root: String, _ result: Result<FixPatch.Fix?, PullRequests.Failure>) {
        guard jobs[root] != nil else { return }
        switch result {
        case .success(let fix?): finish(root, .ready(fix))
        case .success(nil): finish(root, .noChanges)
        case .failure(let failure): finish(root, .failed(failure.message))
        }
    }

    private func finish(_ root: String, _ state: State) {
        jobs[root]?.state = state
        AgentsActivity.shared.set("fix:" + root, running: false)
    }

    // MARK: What Claude is doing

    /// While Claude works, its transcript's last lines say what it's doing, read every second.
    private func startPolling() {
        guard poll == nil else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { FixJobs.shared.readActivity() }
        }
    }

    private func readActivity() {
        let working = jobs.values.filter { job in
            if case .fixing = job.state { return true }
            return false
        }
        guard !working.isEmpty else {
            poll?.invalidate()
            poll = nil
            return
        }
        for job in working {
            guard let file = job.transcript else { continue }
            let root = job.root
            DispatchQueue.global(qos: .utility).async {
                let activity = FixPatch.activity(transcript: Self.tail(of: file), root: root)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let activity, case .fixing(let shown)? = FixJobs.shared.jobs[root]?.state,
                              shown != activity else { return }
                        FixJobs.shared.jobs[root]?.state = .fixing(activity: activity)
                    }
                }
            }
        }
    }

    /// The last 64 KB of a file.
    nonisolated private static func tail(of path: String) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    // MARK: Accept, Reject

    /// Accept: commits only the fix's files and pushes; then, when ticked, replies "Fixed in abc1234" and resolves.
    func accept(root: String) {
        guard let job = jobs[root], case .ready(let fix) = job.state else { return }
        jobs[root]?.state = .committing
        jobs[root]?.error = nil
        let gh = PullRequests.executable()
        DispatchQueue.global(qos: .userInitiated).async {
            switch FixPatch.commit(fix, message: job.message, root: root) {
            case .failure(let failure):
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        FixJobs.shared.jobs[root]?.state = .ready(fix)
                        FixJobs.shared.jobs[root]?.error = failure.message
                    }
                }
            case .success(let sha):
                let outcome = Self.publish(sha: sha, root: root, threads: job.replyAndResolve ? job.threadIDs : [],
                                           gh: gh)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { FixJobs.shared.published(root, outcome) }
                }
            }
        }
    }

    /// Retry push, after a push that failed.
    func retryPush(root: String) {
        guard let job = jobs[root], case .pushFailed(let sha, _) = job.state else { return }
        jobs[root]?.state = .committing
        let gh = PullRequests.executable()
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Self.publish(sha: sha, root: root, threads: job.replyAndResolve ? job.threadIDs : [], gh: gh)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { FixJobs.shared.published(root, outcome) }
            }
        }
    }

    /// The push, then each thread's reply and resolve.
    nonisolated private static func publish(sha: String, root: String, threads: [String], gh: String?) -> State {
        if case .failure(let failure) = FixPatch.push(root: root) {
            return .pushFailed(sha: sha, message: failure.message)
        }
        var failures: [String] = []
        for thread in threads {
            for arguments in [ReviewMutations.reply(threadID: thread, body: FixPatch.reply(sha: sha)),
                              ReviewMutations.resolve(threadID: thread)] {
                switch GitHubCLI.run(gh, arguments) {
                case .failure(let failure):
                    failures.append(failure.message)
                case .success(let data):
                    if case .failure(let failure) = GitHubCLI.graphQLData(data) { failures.append(failure.message) }
                }
            }
        }
        return .done(sha: sha, note: failures.first.map { "Pushed, but a reply or resolve failed: \($0)" })
    }

    private func published(_ root: String, _ state: State) {
        jobs[root]?.state = state
        guard let key = jobs[root]?.key else { return }
        // The new commit, the replies and the resolved threads show on the pages, the inbox and the side bar's counts.
        PullRequestStore.shared.refreshReview(key)
        PullRequestStore.shared.load(key, root: root, force: true)
        PullRequestsModel.shared.load(key.repository, force: true)
    }

    /// Reject: puts back what the fix changed. Files changed again since it was ready are kept and named.
    func reject(root: String) {
        guard let job = jobs[root], case .ready(let fix) = job.state else { return }
        jobs[root]?.state = .rejecting
        DispatchQueue.global(qos: .userInitiated).async {
            let result = FixPatch.revert(fix, root: root)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let fixes = FixJobs.shared
                    switch result {
                    case .success(let kept):
                        if kept.isEmpty { fixes.jobs[root] = nil } else { fixes.jobs[root]?.state = .rejected(kept: kept) }
                    case .failure(let failure):
                        fixes.jobs[root]?.state = .ready(fix)
                        fixes.jobs[root]?.error = failure.message
                    }
                }
            }
        }
    }

    /// Clears a finished job: no changes, done, rejected, failed, or a push the user gives up on.
    func dismiss(root: String) {
        guard let job = jobs[root] else { return }
        if case .pushFailed = job.state {} else if job.isBusy { return }
        jobs[root] = nil
    }

    func setReplyAndResolve(_ on: Bool, root: String) {
        jobs[root]?.replyAndResolve = on
    }
}
