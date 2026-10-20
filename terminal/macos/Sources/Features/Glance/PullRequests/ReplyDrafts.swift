import AppKit
import GlanceCore
import GlanceKit

/// Claude's reply drafts for the inbox's threads waiting on the user (spec 2026-10-07-pr-manager-design.md, "Claude":
/// one-shot and read-only, cached by comment, at most three at a time), only when the user asks. A draft answers the
/// thread's last comment, so a new comment gets a new draft.
@MainActor
final class ReplyDrafts: ObservableObject {
    static let shared = ReplyDrafts()

    enum State: Equatable {
        /// Waiting for one of the three runs.
        case queued
        case drafting
        case ready(String)
        case failed(String)
        case discarded
    }

    /// What a draft answers: a thread on a pull request, in a project, for the viewer.
    struct Request {
        let thread: ReviewThreads.Thread
        let number: Int
        let title: String
        let repository: String
        let viewer: String
        /// Nil runs Claude in the scratch folder.
        let root: String?

        /// The comment the draft answers, the thread's last: the draft's key.
        var commentID: String { thread.comments.last?.id ?? thread.id }
    }

    /// By the answered comment's id.
    @Published private(set) var states: [String: State] = [:]
    /// The user's edits of ready drafts, by the answered comment's id.
    @Published private var edits: [String: String] = [:]
    /// Claude Code wasn't found: no more drafts this session.
    private var unavailable = false
    private var waiting: [Request] = []
    /// Drafts holding one of the three slots: reading the hunk, or Claude at work.
    private var running: Set<String> = []
    private var runs: [String: ClaudeOneShot.Run] = [:]
    private static let atOnce = 3

    private init() {}

    func state(_ commentID: String) -> State? { states[commentID] }

    /// A ready draft's text, as the user left it.
    func text(_ commentID: String) -> String {
        if let edited = edits[commentID] { return edited }
        if case .ready(let text)? = states[commentID] { return text }
        return ""
    }

    func setText(_ text: String, for commentID: String) {
        edits[commentID] = text
    }

    /// Drafts a reply when the user asks, unless one is under way, ready or failed. A saved draft comes back from disk;
    /// after a Discard, asking again drafts anew.
    func request(_ request: Request) {
        let id = request.commentID
        guard states[id] == nil || states[id] == .discarded, !unavailable else { return }
        if let stored = ReplyDraftCache.shared.draft(id), !stored.discarded {
            states[id] = .ready(stored.text)
            return
        }
        states[id] = .queued
        waiting.append(request)
        next()
    }

    /// Discard: the draft goes for good; one under way stops, and its slot goes to the next.
    func discard(_ commentID: String) {
        runs.removeValue(forKey: commentID)?.cancel()
        waiting.removeAll { $0.commentID == commentID }
        running.remove(commentID)
        states[commentID] = .discarded
        edits[commentID] = nil
        ReplyDraftCache.shared.save("", discarded: true, for: commentID)
        next()
    }

    /// The draft went out as the reply: it's spent.
    func sent(_ commentID: String) {
        discard(commentID)
    }

    /// Retry, after a failed draft.
    func retry(_ request: Request) {
        states[request.commentID] = nil
        self.request(request)
    }

    /// Starts waiting drafts while fewer than three hold a slot.
    private func next() {
        while running.count < Self.atOnce, !waiting.isEmpty {
            start(waiting.removeFirst())
        }
    }

    /// The comment's diff hunk first (one gh call), then Claude.
    private func start(_ request: Request) {
        let id = request.commentID
        states[id] = .drafting
        running.insert(id)
        let gh = PullRequests.executable()
        let arguments = PullRequestClaude.hunkArguments(repository: request.repository,
                                                        commentID: request.thread.comments.first?.databaseID ?? 0)
        DispatchQueue.global(qos: .utility).async {
            let hunk = (try? GitHubCLI.run(gh, arguments).get()).map { String(decoding: $0, as: UTF8.self) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { ReplyDrafts.shared.draft(request, hunk: hunk) }
            }
        }
    }

    /// Claude, read-only, in the project, unless the draft was discarded meanwhile.
    private func draft(_ request: Request, hunk: String?) {
        let id = request.commentID
        guard states[id] == .drafting else {
            finished(id)
            return
        }
        let prompt = PullRequestClaude.draftPrompt(request.thread, number: request.number, title: request.title,
                                                   repository: request.repository, viewer: request.viewer, hunk: hunk)
        runs[id] = ClaudeOneShot.run(arguments: PullRequestClaude.draftArguments(), prompt: prompt,
                                     folder: request.root) { result in
            ReplyDrafts.shared.drafted(id, result)
        }
    }

    private func drafted(_ id: String, _ result: Result<String, PullRequestClaude.Failure>) {
        guard states[id] == .drafting else {
            finished(id)
            return
        }
        switch result {
        case .success(let text):
            states[id] = .ready(text)
            ReplyDraftCache.shared.save(text, discarded: false, for: id)
        case .failure(let failure) where failure.kind == .notInstalled:
            // No Claude Code: the cards keep their usual actions, and nothing else is queued.
            unavailable = true
            states[id] = nil
            for request in waiting { states[request.commentID] = nil }
            waiting.removeAll()
        case .failure(let failure):
            states[id] = .failed(failure.message)
        }
        finished(id)
    }

    private func finished(_ id: String) {
        runs[id] = nil
        running.remove(id)
        next()
    }
}

/// Write with Claude, in a reply box: Claude writes the reply from the thread, and from what the user typed when
/// there's something there (their notes). The text replaces the box's, for the user to edit and send. One run per
/// thread, by its id; nothing is kept.
@MainActor
final class ReplyWriter: ObservableObject {
    static let shared = ReplyWriter()

    @Published private(set) var writing: Set<String> = []
    @Published private(set) var errors: [String: String] = [:]
    private var runs: [String: ClaudeOneShot.Run] = [:]

    private init() {}

    /// The diff hunk (one gh call), then read-only Claude in the project; `done` gets the reply.
    func write(_ request: ReplyDrafts.Request, notes: String, done: @escaping @MainActor (String) -> Void) {
        let id = request.thread.id
        guard !writing.contains(id) else { return }
        writing.insert(id)
        errors[id] = nil
        let gh = PullRequests.executable()
        let arguments = PullRequestClaude.hunkArguments(repository: request.repository,
                                                        commentID: request.thread.comments.first?.databaseID ?? 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let hunk = (try? GitHubCLI.run(gh, arguments).get()).map { String(decoding: $0, as: UTF8.self) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { ReplyWriter.shared.run(request, notes: notes, hunk: hunk, done: done) }
            }
        }
    }

    /// Stop: the box keeps what the user typed.
    func stop(_ threadID: String) {
        runs.removeValue(forKey: threadID)?.cancel()
        writing.remove(threadID)
    }

    func clearError(_ threadID: String) { errors[threadID] = nil }

    private func run(_ request: ReplyDrafts.Request, notes: String, hunk: String?,
                     done: @escaping @MainActor (String) -> Void) {
        let id = request.thread.id
        guard writing.contains(id) else { return }
        let prompt = PullRequestClaude.draftPrompt(request.thread, number: request.number, title: request.title,
                                                   repository: request.repository, viewer: request.viewer,
                                                   hunk: hunk, notes: notes)
        runs[id] = ClaudeOneShot.run(arguments: PullRequestClaude.draftArguments(), prompt: prompt,
                                     folder: request.root) { result in
            let writer = ReplyWriter.shared
            guard writer.writing.contains(id) else { return }
            writer.runs[id] = nil
            writer.writing.remove(id)
            switch result {
            case .success(let text): done(text.trimmingCharacters(in: .whitespacesAndNewlines))
            case .failure(let failure): writer.errors[id] = "Claude couldn't write the reply: \(failure.message)"
            }
        }
    }
}

/// Reply drafts kept on disk by the comment they answer, so each runs once, and a Discard is remembered
/// (`~/Library/Application Support/Glance/reply-drafts.json`, the newest 200).
@MainActor
final class ReplyDraftCache {
    static let shared = ReplyDraftCache()

    struct Stored: Codable {
        var text: String
        var discarded: Bool
        var at: Date
    }

    private var stored: [String: Stored]
    private let file: URL

    private init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Glance")
        file = folder.appendingPathComponent("reply-drafts.json")
        stored = (try? JSONDecoder().decode([String: Stored].self, from: Data(contentsOf: file))) ?? [:]
    }

    func draft(_ commentID: String) -> Stored? { stored[commentID] }

    func save(_ text: String, discarded: Bool, for commentID: String) {
        stored[commentID] = Stored(text: text, discarded: discarded, at: Date())
        if stored.count > 200 {
            for old in stored.sorted(by: { $0.value.at < $1.value.at }).prefix(stored.count - 200) {
                stored[old.key] = nil
            }
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(stored).write(to: file, options: .atomic)
    }
}
