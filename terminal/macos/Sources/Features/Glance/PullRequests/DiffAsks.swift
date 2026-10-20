import AppKit
import GlanceCore
import GlanceKit

/// Ask Claude in diffs (spec 2026-10-08-pr-ask-lists-design.md, "Stage 3"): the answer boxes of each PR tab and New
/// Pull Request tab, by file, and one review-mode Inline Ask runner per tab (a `claude -p` per box). Closing a box or
/// its tab stops its Claude; an idle one exits after 10 minutes and the next question starts it again.
@MainActor
final class DiffAsks: ObservableObject {
    static let shared = DiffAsks()

    struct Turn: Equatable {
        let question: String
        var answer = ""
    }

    struct Box: Identifiable, Equatable {
        let id: String
        /// The file's path, with the commit first in a commit's view ("sha:path"): a commit's lines aren't the PR's.
        let path: String
        let scope: DiffAsk.Scope
        var turns: [Turn] = []
        /// What Claude is doing ("Reading auth.swift…"), while a turn runs.
        var tool: String?
        var running = false
        var error: String?

        /// Where a lines box sits: under its last line. Nil for a file box (above the diff).
        var anchor: ReviewThreads.Anchor? {
            if case .lines(_, let end) = scope { return end }
            return nil
        }

        /// "About this file", "Line 42", "Lines 40–44".
        var title: String {
            if scope == .file { return "About this file" }
            let place = DiffAsk.place(scope)
            return place.prefix(1).uppercased() + place.dropFirst()
        }
    }

    /// A tab that asks: its key, the folder Claude runs in (nil: the scratch folder) and what its diff is.
    struct Owner {
        let key: String
        let folder: String?
        let subject: DiffAsk.Subject
    }

    /// By owner key, in the order they opened.
    @Published private(set) var all: [String: [Box]] = [:]
    private var sessions: [String: InlineAskSessions] = [:]
    /// What a box's first message needs, by box id.
    private var contexts: [String: (owner: Owner, file: PullRequestDiff.File)] = [:]
    /// Boxes whose Claude has its first message (else the next question starts it).
    private var started: Set<String> = []

    private init() {}

    static func key(_ key: PullRequestStore.Key) -> String { RepositoryFolders.key(key.repository) + "#\(key.number)" }
    static func key(newPullRequest root: String) -> String { "new:" + root }

    func boxes(_ owner: String, path: String) -> [Box] { (all[owner] ?? []).filter { $0.path == path } }

    /// Opens a box: a lines box with its question, asked at once; a file box empty, waiting for one.
    @discardableResult
    func open(_ owner: Owner, file: PullRequestDiff.File, path: String, scope: DiffAsk.Scope,
              question: String?) -> String {
        let id = UUID().uuidString
        all[owner.key, default: []].append(Box(id: id, path: path, scope: scope))
        contexts[id] = (owner, file)
        if let question, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ask(id, owner: owner.key, question: question)
        }
        return id
    }

    func ask(_ id: String, owner: String, question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, let context = contexts[id],
              let box = all[owner]?.first(where: { $0.id == id }), !box.running else { return }
        update(id, owner: owner) {
            $0.turns.append(Turn(question: question))
            $0.running = true
            $0.error = nil
        }
        let sessions = self.sessions(context.owner)
        if started.contains(id) {
            sessions.followUp(id: id, question: question)
            return
        }
        started.insert(id)
        let request = InlineAsk.Request(id: id, path: context.file.path, start: 0, end: 0, text: "", before: "",
                                        after: "", question: question)
        let scope = box.scope
        sessions.start(request) { question in
            DiffAsk.message(subject: context.owner.subject, file: context.file, scope: scope,
                            localClone: context.owner.folder != nil, question: question)
        }
    }

    /// Stop: ends the turn and its Claude; the next question starts a new one.
    func stopTurn(_ id: String, owner: String) {
        sessions[owner]?.stop(id: id)
        started.remove(id)
        update(id, owner: owner) {
            $0.running = false
            $0.tool = nil
        }
    }

    /// Retry after a failure: the last question again, from a new Claude.
    func retry(_ id: String, owner: String) {
        guard let box = all[owner]?.first(where: { $0.id == id }), let last = box.turns.last else { return }
        sessions[owner]?.stop(id: id)
        started.remove(id)
        update(id, owner: owner) {
            $0.turns.removeLast()
            $0.error = nil
            $0.running = false
        }
        ask(id, owner: owner, question: last.question)
    }

    func close(_ id: String, owner: String) {
        sessions[owner]?.stop(id: id)
        started.remove(id)
        contexts[id] = nil
        all[owner]?.removeAll { $0.id == id }
    }

    /// The tab closed: every box and its Claude go.
    func closeAll(_ owner: String) {
        sessions.removeValue(forKey: owner)?.stopAll()
        for box in all[owner] ?? [] {
            started.remove(box.id)
            contexts[box.id] = nil
        }
        all[owner] = nil
    }

    private func sessions(_ owner: Owner) -> InlineAskSessions {
        if let sessions = sessions[owner.key] { return sessions }
        let key = owner.key
        let made = InlineAskSessions(folder: owner.folder ?? ClaudeOneShot.scratchFolder, rules: DiffAsk.rules) {
            event, request in
            MainActor.assumeIsolated { DiffAsks.shared.received(event, id: request.id, owner: key) }
        }
        sessions[key] = made
        return made
    }

    private func received(_ event: InlineAsk.Event, id: String, owner: String) {
        update(id, owner: owner) { box in
            switch event {
            case .text(let text):
                if !box.turns.isEmpty { box.turns[box.turns.count - 1].answer += text }
                box.tool = nil
            case .tool(let label):
                box.tool = label
            case .done:
                box.running = false
                box.tool = nil
            case .failed(let message):
                box.running = false
                box.tool = nil
                box.error = message
            }
        }
    }

    private func update(_ id: String, owner: String, _ change: (inout Box) -> Void) {
        guard let index = all[owner]?.firstIndex(where: { $0.id == id }), var box = all[owner]?[index] else { return }
        change(&box)
        all[owner]?[index] = box
    }
}
