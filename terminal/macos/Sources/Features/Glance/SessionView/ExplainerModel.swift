import AppKit
import Combine
import GlanceCore
import GlanceKit

/// One session's explainers (spec 2026-11-03-explainer-mode-design.md): what each reply's page is doing, which replies
/// show theirs, the session's switch and the mode's automatic rules. Nothing here starts Claude unless the user clicked
/// Explain or turned the mode on, and a reply already in the transcript never gets a page on its own.
@MainActor
final class ExplainerModel: ObservableObject {
    enum Reply: Equatable {
        case writing(answer: String?)
        case ready(ExplainerPage)
        case failed(String)
    }

    /// Asks the timeline to bring a reply's top into view. Each request is new, even for the same reply.
    struct ScrollRequest: Equatable {
        let reply: String
        let count: Int
    }

    @Published private(set) var replies: [String: Reply] = [:]
    /// Which of Explainer and Reply a reply shows, when the user chose; otherwise it follows the mode.
    @Published private(set) var chosen: [String: Bool] = [:]
    @Published private(set) var stepsOpen: Set<String> = []
    @Published private(set) var modeOn = false
    @Published private(set) var heights: [String: CGFloat] = [:]
    /// The pages with a live web view, newest last. The rest wait as placeholders at their known height.
    @Published private(set) var live: [String] = []
    @Published private(set) var onScreen: [String] = []
    @Published private(set) var scrollRequest: ScrollRequest?
    /// While a new page takes its height, the timeline doesn't chase the bottom.
    private(set) var followPausedUntil = Date.distantPast

    private static let maxLive = 3
    private static let lastChoiceKey = "explainerModeLastChoice"

    private let store = ExplainerStore()
    private var session: String?
    private var cwd: String?
    private var timeline: SessionTimeline?
    /// When this session's view opened: only replies after this may act on their own.
    private var openedAt = Date()
    private var handled = Set<String>()
    private var scrollCount = 0

    // Set by the session view's model.
    var insertInComposer: ((String) -> Void)?
    var openFile: ((String) -> Void)?
    var isFront: () -> Bool = { false }
    var checks: () -> [ProofCheckRun] = { [] }

    static var isEnabled: Bool {
        StudioFeatures.shared.isOn(.commandCenter) && StudioFeatures.shared.isOn(.explainerMode)
    }

    // MARK: Following the session

    func follow(session next: String?, cwd nextCwd: String?) {
        cwd = nextCwd
        guard next != session else { return }
        if let session { ExplainerQueue.shared.cancelAutomatic(session: session) }
        stopVoice()
        session = next
        timeline = nil
        replies = [:]
        chosen = [:]
        stepsOpen = []
        heights = [:]
        live = []
        onScreen = []
        handled = []
        scrollRequest = nil
        openedAt = Date()
        guard let next, Self.isEnabled else { modeOn = false; return }
        let last = UserDefaults.standard.bool(forKey: Self.lastChoiceKey)
        let store = store
        let saved = store.mode(session: next)
        modeOn = saved ?? last
        Task { [weak self] in
            let pages = await Task.detached(priority: .utility) {
                store.replies(session: next).compactMap { reply in store.page(session: next, reply: reply).map { (reply, $0) } }
            }.value
            guard let self, self.session == next else { return }
            for (reply, page) in pages where self.replies[reply] == nil { self.replies[reply] = .ready(page) }
        }
    }

    func stop() {
        if let session { ExplainerQueue.shared.cancelAutomatic(session: session) }
        stopVoice()
    }

    private func stopVoice() {
        guard let session else { return }
        let prefix = session + "/"
        if let page = ExplainerVoicePlayer.shared.current?.page, page.hasPrefix(prefix) { ExplainerVoicePlayer.shared.stop() }
    }

    func timelineChanged(_ next: SessionTimeline) {
        timeline = next
        guard Self.isEnabled, let session else { return }
        // A newer turn started: runs nobody clicked for are no longer wanted.
        if next.live.working {
            for reply in ExplainerQueue.shared.cancelAutomatic(session: session) { replies[reply] = nil }
            return
        }
        guard modeOn, let newest = ExplainerTurns.newestFinished(next.rows, working: false), !handled.contains(newest),
              let row = next.rows.last(where: { $0.id == newest }) else { return }
        handled.insert(newest)
        guard ExplainerTurns.finishedSince(openedAt, reply: row), replies[newest] == nil else { return }
        act(on: newest, row: row, ended: next.endedTurns)
    }

    private func act(on reply: String, row: TimelineRow, ended: Set<String>) {
        guard case .prose(let markdown) = row.kind else { return }
        switch ExplainerTurns.automatic(reply: reply, markdown: markdown, ended: ended) {
        case .page: explain(reply, automatic: true)
        case .readAloud: if isFront() { ReplyVoice.shared.read(id: reply, markdown: markdown, kokoroOnly: true) }
        case .nothing: break
        }
    }

    // MARK: The switch

    func setMode(_ on: Bool) {
        guard let session, on != modeOn else { return }
        modeOn = on
        store.setMode(on, session: session)
        UserDefaults.standard.set(on, forKey: Self.lastChoiceKey)
        // Every reply goes back to following the mode: off is markdown, and what was made is kept.
        chosen = [:]
        guard on else {
            for reply in ExplainerQueue.shared.cancelAutomatic(session: session) { replies[reply] = nil }
            stopVoice()
            return
        }
        // Turning it on explains the newest reply, unless Claude is already on the next one.
        guard let timeline, !timeline.live.working, let newest = ExplainerTurns.newestFinished(timeline.rows, working: false),
              let row = timeline.rows.last(where: { $0.id == newest }) else { return }
        handled.insert(newest)
        if replies[newest] == nil { act(on: newest, row: row, ended: timeline.endedTurns) }
    }

    // MARK: A reply

    /// Explain: a page already made opens at once and costs nothing. Otherwise a side Claude writes one.
    func explain(_ reply: String, automatic: Bool = false) {
        guard let session else { return }
        if !automatic { chosen[reply] = true }
        if case .ready = replies[reply] { bringIntoView(reply); return }
        if case .writing = replies[reply] { return }
        guard let timeline, let turn = ExplainerTurns.turn(endingAt: reply, rows: timeline.rows) else { return }
        replies[reply] = .writing(answer: nil)
        ExplainerQueue.shared.enqueue(session: session, reply: reply, automatic: automatic, prompt: ExplainerInput.prompt(turn: turn)) { [weak self] event in
            self?.received(event, reply: reply, session: session)
        }
    }

    private func received(_ event: ExplainerPageRun.Event, reply: String, session sent: String) {
        guard sent == session else { return }
        switch event {
        case .answer(let answer):
            replies[reply] = .writing(answer: answer)
        case .page(let page):
            replies[reply] = .ready(page)
            ExplainerVoicePlayer.shared.prepare(beats: beats(reply, page))
            if showsPage(reply) {
                bringIntoView(reply)
                if isFront() { play(reply, page: page) }
            }
        case .failed(let message):
            replies[reply] = .failed(message)
        }
    }

    /// The sandbox couldn't be set up: the page must not show, so it counts as a failed run.
    func pageCantShow(_ reply: String, reason: String) {
        replies[reply] = .failed(reason)
    }

    func showsPage(_ reply: String) -> Bool { chosen[reply] ?? modeOn }

    func choose(_ reply: String, page: Bool) {
        chosen[reply] = page
        if !page, let key = key(reply) { ExplainerVoicePlayer.shared.stop(page: key) }
    }

    func toggleSteps(_ reply: String) {
        if !stepsOpen.insert(reply).inserted { stepsOpen.remove(reply) }
    }

    func facts(_ reply: String) -> ExplainerFacts? {
        guard let timeline, let turn = ExplainerTurns.turn(endingAt: reply, rows: timeline.rows) else { return nil }
        return ExplainerFacts(turn: turn, checks: checks())
    }

    /// The steps of turns whose page shows.
    func fold(blocks: [TimelineBlock]) -> ExplainerStepsFold {
        guard Self.isEnabled else { return ExplainerStepsFold() }
        let shown = Set(replies.compactMap { reply, state -> String? in
            if case .ready = state, showsPage(reply) { return reply }
            return nil
        })
        return shown.isEmpty ? ExplainerStepsFold() : ExplainerTurns.fold(blocks: blocks, replies: shown, open: stepsOpen)
    }

    private func bringIntoView(_ reply: String) {
        followPausedUntil = Date().addingTimeInterval(2)
        scrollCount += 1
        scrollRequest = ScrollRequest(reply: reply, count: scrollCount)
    }

    // MARK: The page on screen

    func height(_ reply: String, page: ExplainerPage) -> CGFloat {
        heights[reply] ?? CGFloat(120 + 260 * page.beats.count)
    }

    func setHeight(_ reply: String, _ height: CGFloat) {
        guard heights[reply] != height else { return }
        heights[reply] = height
        // Still settling after it appeared: stay on its top.
        if Date() < followPausedUntil, scrollRequest?.reply == reply { bringIntoView(reply) }
    }

    func appeared(_ reply: String) {
        if !onScreen.contains(reply) { onScreen.append(reply) }
        guard live.last != reply else { return }
        live.removeAll { $0 == reply }
        live.append(reply)
        if live.count > Self.maxLive { live.removeFirst(live.count - Self.maxLive) }
    }

    func disappeared(_ reply: String) {
        onScreen.removeAll { $0 == reply }
    }

    /// The page the voice bar is for: the one this session is playing, or the page last come into view.
    var barPage: (reply: String, page: ExplainerPage)? {
        let playing = ExplainerVoicePlayer.shared.current?.page
        let candidates = replies.keys.filter { key($0) == playing && playing != nil } + onScreen.reversed()
        for reply in candidates {
            if case .ready(let page) = replies[reply], showsPage(reply) { return (reply, page) }
        }
        return nil
    }

    // MARK: The voice

    func key(_ reply: String) -> String? { session.map { "\($0)/\(reply)" } }

    func beats(_ reply: String, _ page: ExplainerPage) -> [ExplainerVoicePlayer.Beat] {
        guard let session else { return [] }
        return page.beats.compactMap { beat in
            store.audio(session: session, reply: reply, beat: beat.id).map { .init(say: beat.say, file: $0) }
        }
    }

    func play(_ reply: String, page: ExplainerPage, from beat: Int = 0) {
        guard let key = key(reply) else { return }
        ExplainerVoicePlayer.shared.play(page: key, beats: beats(reply, page), from: beat)
    }

    // MARK: What the page asks for

    func received(_ message: ExplainerBridge.Message, reply: String, page: ExplainerPage) {
        switch message {
        case .ready: break
        case .height(let height): setHeight(reply, CGFloat(height))
        case .beat: break
        case .play(let index): if page.beats.indices.contains(index) { play(reply, page: page, from: index) }
        case .ask(let title): insertInComposer?(ExplainerBridge.askText(title: title))
        case .open(let path): if let file = ExplainerBridge.safeFile(path, root: cwd) { openFile?(file) }
        }
    }
}

/// Runs pages across every session, at most two at a time; the rest wait. A clicked run is never cancelled by a newer
/// turn. Each page is saved as it arrives, whether or not its session is still on screen.
@MainActor
final class ExplainerQueue {
    static let shared = ExplainerQueue()
    private static let limit = 2

    private final class Job {
        let session: String
        let reply: String
        let automatic: Bool
        let prompt: String
        let onEvent: @MainActor (ExplainerPageRun.Event) -> Void
        var run: ExplainerPageRun?

        init(session: String, reply: String, automatic: Bool, prompt: String, onEvent: @escaping @MainActor (ExplainerPageRun.Event) -> Void) {
            self.session = session
            self.reply = reply
            self.automatic = automatic
            self.prompt = prompt
            self.onEvent = onEvent
        }
    }

    private var waiting: [Job] = []
    private var running: [Job] = []
    private let store = ExplainerStore()

    func enqueue(session: String, reply: String, automatic: Bool, prompt: String, onEvent: @escaping @MainActor (ExplainerPageRun.Event) -> Void) {
        waiting.append(Job(session: session, reply: reply, automatic: automatic, prompt: prompt, onEvent: onEvent))
        startNext()
    }

    /// Ends this session's automatic runs and returns their replies.
    @discardableResult
    func cancelAutomatic(session: String) -> [String] {
        let isTarget = { (job: Job) in job.session == session && job.automatic }
        let ended = waiting.filter(isTarget) + running.filter(isTarget)
        guard !ended.isEmpty else { return [] }
        waiting.removeAll(where: isTarget)
        running.removeAll(where: isTarget)
        ended.forEach { $0.run?.cancel() }
        startNext()
        return ended.map(\.reply)
    }

    private func startNext() {
        while running.count < Self.limit, !waiting.isEmpty {
            let job = waiting.removeFirst()
            let run = ExplainerPageRun()
            job.run = run
            running.append(job)
            run.start(prompt: job.prompt) { [weak self, weak job] event in
                guard let self, let job else { return }
                switch event {
                case .answer:
                    break
                case .page(let page):
                    try? self.store.save(fragment: page.fragment, model: ExplainerPageRun.model, session: job.session, reply: job.reply)
                    self.finished(job)
                case .failed:
                    self.finished(job)
                }
                job.onEvent(event)
            }
        }
    }

    private func finished(_ job: Job) {
        running.removeAll { $0 === job }
        startNext()
    }
}
