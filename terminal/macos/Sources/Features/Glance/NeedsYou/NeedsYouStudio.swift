import AppKit
import GlanceCore
import GlanceKit

/// Studio's side of "Claude needs you" (spec 2026-10-11-needs-input-orb-design.md): follows waiting tool calls,
/// reads those splits' screens every half second, keeps the prompts, lights the orbs, shows the cards, and types answers.
@MainActor
final class NeedsYouStudio {
    static let shared = NeedsYouStudio()

    private var book = PromptBook()
    private var poll: Timer?
    private var running = false
    /// Answers typed and not yet seen landing (key: surface + call id): the dialog they were typed into, and when
    /// the last key went. A second click or hotkey before the split redraws would pass the same-dialog check and type
    /// into whatever dialog comes next, so answers for that prompt wait until it's gone or, after its keys went, its
    /// screen changed (or a few seconds pass, in case the keys did nothing).
    private struct Sent {
        let screen: DialogScreen
        let typed: Date
    }
    private var inFlight: [String: Sent] = [:]
    private static let inFlightLimit: TimeInterval = 3

    var prompts: [PendingPrompt] { book.ordered }

    func start() {
        guard StudioFeatures.shared.isOn(.needsYou), !running else { return }
        running = true
        NeedsYouCards.onAnswer = { [weak self] prompt, answer in self?.answer(prompt, answer) }
        NeedsYouCards.onOpen = { prompt in
            NoticeRouter.open(TerminalNotices.notice(surface: prompt.surface, cwd: prompt.cwd, title: "Claude",
                                                     body: "", at: Date()))
        }
        OrbAttention.onPromptClick = { NeedsYouCards.reveal(nil, takeKeyboard: false) }
        OrbChannelHub.shared.promptCovers = { [weak self] surface, tool in
          MainActor.assumeIsolated { self?.book.prompts[surface]?.call.name == tool }
        }
        // Claude Code's own permission notice is a cue to look now, with Notifications on or off.
        TerminalNoticeTap.shared.start()
    }

    func stop() {
        running = false
        poll?.invalidate()
        poll = nil
        book = PromptBook()
        inFlight = [:]
        OrbAttention.onPromptClick = nil
        OrbChannelHub.shared.promptCovers = nil
        NeedsYouCards.onAnswer = nil
        NeedsYouCards.onOpen = nil
        publish(previous: [])
    }

    /// A prompt or finished turn: that transcript's calls no longer wait.
    func transcript(_ event: TranscriptWatcher.Event) {
        guard running else { return }
        let before = book
        book.turn(file: event.file)
        if book.ordered != before.ordered { publish(previous: before.ordered) }
    }

    func tool(_ note: TranscriptWatcher.ToolNote) {
        guard running else { return }
        let before = book.ordered
        book.tool(note.event, file: note.file, now: Date())
        if book.ordered != before { publish(previous: before) }
        if case .settled = note.event.kind { check() }
        ensurePolling()
    }

    /// Claude Code's own "needs your permission" notice for a split: read the splits now, and say whether a prompt
    /// card covers that split, so the Notifications nudge stays away. Reads screens: never call it from inside a
    /// Ghostty callback (`TerminalNoticeTap` hops to the main queue first).
    func noticed(surface: String) -> Bool {
        guard running else { return false }
        check()
        return book.prompts[surface] != nil
    }

    private func ensurePolling() {
        guard running, poll == nil, !book.waiting.isEmpty else { return }
        // Each check reads every owned split's screen: once a second is soon enough to catch a prompt.
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { NeedsYouStudio.shared.check() }
        }
        poll?.tolerance = 0.25
    }

    private func check() {
        guard running else { return }
        let now = Date()
        let before = book.ordered
        book.expire(now: now)
        let folders = book.folders(now: now)
        var seen = Set<String>()
        for controller in TerminalController.all {
            for view in controller.surfaceTree {
                let id = view.id.uuidString
                guard let pwd = view.pwd, book.prompts[id] != nil || FolderOwnership.isOwned(pwd, by: folders)
                else { continue }
                seen.insert(id)
                book.screen(surface: id, cwd: pwd, text: SurfaceScreen.visibleText(view), now: now)
            }
        }
        for id in book.prompts.keys where !seen.contains(id) { book.screen(surface: id, cwd: nil, text: nil, now: now) }
        if book.ordered != before { publish(previous: before) }
        // An answer has landed once its prompt is gone or its screen moved on.
        inFlight = inFlight.filter { key, sent in
            guard let prompt = book.prompts[String(key.prefix { $0 != "|" })], Self.key(prompt) == key else { return false }
            return !Self.landed(sent, screen: prompt.screen, now: now)
        }
        if book.waiting.isEmpty && book.prompts.isEmpty {
            poll?.invalidate()
            poll = nil
        }
    }

    private func publish(previous: [PendingPrompt]) {
        let prompts = book.ordered
        NeedsYouCards.update(prompts)
        OrbAttention.setPrompt(prompts.first.map(NeedsYouRules.caption))
        NeedsYouOrb.shared.update(pending: !prompts.isEmpty)
        let old = Set(previous.map(Self.key))
        for prompt in prompts where !old.contains(Self.key(prompt)) {
            if prompt.kind == .permission {
                OrbChannelHub.shared.dropPermissionCards(surface: prompt.surface, tool: prompt.call.name)
            }
            switch NeedsYouRules.open(setting: Prefs.needsYouOpen, splitFocused: isFocused(prompt.surface)) {
            case .none: break
            case .card: NeedsYouCards.reveal(prompt, takeKeyboard: false)
            case .cardAndKeyboard: NeedsYouCards.reveal(prompt, takeKeyboard: true)
            }
        }
    }

    private static func key(_ prompt: PendingPrompt) -> String { prompt.surface + "|" + prompt.call.id }

    /// The keys went and the split shows something else since (or they've had long enough).
    private static func landed(_ sent: Sent, screen: DialogScreen, now: Date) -> Bool {
        let since = now.timeIntervalSince(sent.typed)
        return since >= inFlightLimit || (since >= 0.1 && screen != sent.screen)
    }

    private func isFocused(_ surface: String) -> Bool {
        guard NSApp.isActive, let view = self.view(surface) else { return false }
        return view.focused && view.window?.isKeyWindow == true
    }

    private func view(_ surface: String) -> Ghostty.SurfaceView? {
        UUID(uuidString: surface).flatMap { (NSApp.delegate as? AppDelegate)?.findSurface(forUUID: $0) }
    }

    /// Spec §4: re-read the screen, and type only if the same dialog is still on it, and no answer for it is still
    /// on its way (one answer per screen: a multi-select's toggles go one at a time, each once the box shows it).
    private func answer(_ prompt: PendingPrompt, _ answer: PromptAnswer) {
        guard running else { return }
        let key = Self.key(prompt)
        guard let view = view(prompt.surface), let text = SurfaceScreen.visibleText(view),
              let now = PromptScreen.parse(text), PromptKeys.sameDialog(now, prompt.screen) else {
            NeedsYouCards.answeredElsewhere(prompt.surface)
            check()
            return
        }
        if let sent = inFlight[key], !Self.landed(sent, screen: now, now: Date()) { return }
        // Keys from the screen as it is now: the selection may have moved since the card was drawn.
        guard let keys = PromptKeys.keys(answer, kind: prompt.kind, screen: now) else {
            NSLog("Glance Studio: no keys for a prompt answer on this screen; leaving it to the terminal")
            NeedsYouCards.answeredElsewhere(prompt.surface)
            return
        }
        let duration = SurfaceScreen.send(keys, to: view)
        inFlight[key] = Sent(screen: now, typed: Date().addingTimeInterval(duration))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            MainActor.assumeIsolated { NeedsYouStudio.shared.check() }
        }
    }
}
