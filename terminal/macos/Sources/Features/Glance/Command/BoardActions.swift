import AppKit
import GlanceCore

/// How an answer from a card went. "Answered" shows only after `sent`.
enum BoardAnswerResult {
    /// The answer's keys all went.
    case sent
    /// The prompt on screen isn't the one the card shows, or that can't be told: nothing was answered.
    case changed
    /// The keys couldn't go (the tab's gone, an answer is still on its way).
    case failed
}

/// How a reply from a card went.
enum BoardReplyResult {
    case sent
    /// Nothing was typed. Sending again is fine.
    case refused
    /// It was pasted and its Return held back, so it may be on the tab's line: no retry until the tab has been opened.
    case held
}

/// What a card does. A card can be stale by the moment it's clicked, so each action checks the tab is still there.
@MainActor
enum BoardActions {
    private nonisolated static let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects").path

    /// Reply text typed and not sent, by session. The lazy lists recycle a card that scrolls away, and its reply box
    /// with it, so the text lives here; a successful send clears it.
    static var drafts: [String: String] = [:]

    /// A card's click and ↵: a Studio session opens in Glance mode, one elsewhere its transcript, an ended one its recap.
    static func open(_ card: BoardCard, from window: NSWindow?) {
        let heldOn = held.surface(of: card.id)
        held.opened(card.id)
        switch card.place {
        case .studio(let own):
            // A held reply's text is on the split it went to, which with two tabs on one session needn't be the card's.
            let surface = heldOn ?? own
            guard let controller = TerminalController.all.first(where: { $0.surfaceTree.contains { $0.id == surface } }),
                  let view = (NSApp.delegate as? AppDelegate)?.findSurface(forUUID: surface), let tab = controller.window else {
                BoardModel.shared.notice = "That tab is closed."
                BoardModel.shared.rebuild()
                return
            }
            // The held text is on that line, in front of the user now: the box's copy would only paste it again.
            if heldOn != nil {
                drafts[card.id] = nil
                if BoardModel.shared.reply == card.id { BoardModel.shared.reply = nil }
            }
            _ = controller.glanceSessionModel(following: surface)
            GlanceMode.set(true, in: controller)
            // Select, then makeKey: ordering a tab front in native full screen sends the window off its Space.
            tab.tabGroup?.selectedWindow = tab
            tab.makeKey()
            Ghostty.moveFocus(to: view)
        case .external:
            openTranscript(card, from: window)
        case .nowhere:
            BoardRecap.open(card, from: window)
        }
    }

    /// A reply is typed into a real terminal, so it is offered only where it can land: a card that is not waiting on a
    /// prompt (a typed line would go into the dialog; its buttons answer that).
    static func canReply(_ card: BoardCard) -> Bool { card.canReply && !card.isWaiting }

    /// Splits with a reply on its way: its Return goes a moment after the paste, and a second reply can't slip in between.
    private static var typing = Set<UUID>()
    private static var held = BoardReply.HeldReplies()

    /// A reply to this session had its Return held back, and the tab hasn't been opened since.
    static func isHeld(_ card: BoardCard) -> Bool { held.isHeld(card.id) }

    /// `done` says how it went, and unless it was sent the card keeps the text and says so. The rules are `BoardReply`'s: it goes only to
    /// a split that still exists, still links this session, runs `claude` in front and is at its input line, and they are
    /// asked again just before Return, which stays unpressed if any no longer holds.
    static func send(_ text: String, to card: BoardCard, done: @escaping (BoardReplyResult) -> Void) {
        guard !isHeld(card) else {
            done(.held)
            return
        }
        let clean = BoardReply.sanitized(text)
        guard case .studio(let preferred) = card.place, !clean.isEmpty else {
            done(.refused)
            return
        }
        let session = card.id
        // Glance's knowledge as fresh as it gets: the poll can be a second old.
        NeedsYouStudio.shared.refresh()
        // Re-picked now, not taken from the card: of two tabs on one session the split that is waiting comes first, and
        // a split that died since the card was drawn is passed over.
        let waiting = Set(NeedsYouStudio.shared.prompts.compactMap { UUID(uuidString: $0.surface) })
        let splits = BoardEntries.targets(session: session, links: GlanceTerminalHost.shared.allSessionLinks(),
                                          waiting: waiting, preferred: preferred).compactMap(split)
        guard let surface = BoardReply.target(for: session, text: clean, among: splits), !typing.contains(surface) else {
            done(.refused)
            return
        }
        typing.insert(surface)
        let pasted = SessionInput.send(clean, to: surface, beforeReturn: {
            BoardReply.returnGate(session: session, split: split(surface), text: clean)
        }, done: { sent in
            typing.remove(surface)
            if !sent { held.hold(session, on: surface) }
            done(sent ? .sent : .held)
        })
        if !pasted {
            typing.remove(surface)
            done(.refused)
        }
    }

    /// A split as it is this moment; nil when it's gone.
    private static func split(_ surface: UUID) -> BoardReply.Split? {
        guard let view = (NSApp.delegate as? AppDelegate)?.findSurface(forUUID: surface) else { return nil }
        let linked = GlanceTerminalHost.shared.sessionLink(for: surface)?.sessionID
        return BoardReply.Split(surface: surface, linkedSession: linked,
                                runsClaude: runsClaude(view), hasPrompt: NeedsYouStudio.shared.prompt(forSurface: surface) != nil,
                                screen: SurfaceScreen.visibleText(view), bracketedPaste: view.surfaceModel?.bracketedPaste,
                                callJustStarted: linked.map(NeedsYouStudio.shared.callJustStarted(session:)) ?? false)
    }

    /// The split's foreground program is Claude Code (the side bar's command chip says "claude").
    private static func runsClaude(_ view: Ghostty.SurfaceView) -> Bool {
        guard let pid = view.surfaceModel?.foregroundPID, let process = ProcessArguments.read(pid: pid) else { return false }
        return ChatRoute.isClaude(executable: process.executable, arguments: process.arguments)
    }

    /// Answers the prompt the card shows, only if it is still the one up: checked at the click and again just before
    /// Enter, which also wants the highlight on the answer's row, since this approves a real command. `done` says what
    /// happened; nothing is pressed after a refusal.
    static func answer(_ shown: PendingPrompt, _ answer: PromptAnswer, on card: BoardCard, done: @escaping (BoardAnswerResult) -> Void) {
        // The book's prompt can be a second old.
        NeedsYouStudio.shared.refresh()
        guard refusal(shown, on: card) == nil else {
            BoardModel.shared.rebuild()
            done(.changed)
            return
        }
        var refused = false
        var firstRead: TimeInterval?
        NeedsYouStudio.shared.answerFromBoard(shown, answer, beforeEnter: {
            // Uptime, as a clock set back mustn't stretch the wait.
            let now = ProcessInfo.processInfo.systemUptime
            let waited = now - (firstRead ?? now)
            if firstRead == nil { firstRead = now }
            let live = reading(shown)
            let gate = BoardPromptGuard.enterGate(answer, shown: shown, session: card.id, linked: live.linked, live: live.prompt,
                                                  screen: live.screen, waited: waited)
            if case .refuse(let why) = gate {
                refused = true
                NSLog("Glance Studio: a board answer's Enter was refused: %@", String(describing: why))
            }
            return gate
        }, done: { sent in
            if sent {
                done(.sent)
            } else {
                BoardModel.shared.rebuild()
                done(refused ? .changed : .failed)
            }
        })
    }

    /// Why this answer may not go now.
    private static func refusal(_ shown: PendingPrompt, on card: BoardCard) -> BoardPromptGuard.Refusal? {
        let live = reading(shown)
        let result = BoardPromptGuard.refusal(shown: shown, session: card.id, linked: live.linked, live: live.prompt, screen: live.screen)
        if let result { NSLog("Glance Studio: a board answer was refused: %@", String(describing: result)) }
        return result
    }

    /// The prompt's split as it is this moment: the live link, the book's prompt and a fresh read of the screen.
    private static func reading(_ shown: PendingPrompt) -> (linked: String?, prompt: PendingPrompt?, screen: DialogScreen?) {
        let surface = UUID(uuidString: shown.surface)
        let view = surface.flatMap { (NSApp.delegate as? AppDelegate)?.findSurface(forUUID: $0) }
        return (surface.flatMap { GlanceTerminalHost.shared.sessionLink(for: $0)?.sessionID },
                surface.flatMap { NeedsYouStudio.shared.prompt(forSurface: $0) },
                view.flatMap(SurfaceScreen.visibleText).flatMap(PromptScreen.parse))
    }

    /// The folder `claude --resume` can find this session from; nil when none (its folder is gone). It stats the disk, so
    /// callers run it off the main thread.
    nonisolated static func resumeFolder(_ card: BoardCard) -> String? {
        SessionResume.folder(session: card.id, candidates: [card.cwd, card.worktree].compactMap { $0 }, projects: projects)
    }

    static func resume(_ card: BoardCard, from window: NSWindow?) {
        Task {
            let folder = await Task.detached(priority: .userInitiated) { resumeFolder(card) }.value
            guard let folder, SessionInput.resumeTab(session: card.id, folder: folder, beside: window) else {
                BoardModel.shared.notice = "Couldn't resume that session: its folder is gone."
                return
            }
        }
    }

    static func openTranscript(_ card: BoardCard, from window: NSWindow?) {
        guard let path = card.transcript else {
            BoardModel.shared.notice = "This session has no transcript yet."
            return
        }
        let url = URL(fileURLWithPath: path)
        EditorTabs.open(.razor, root: url.deletingLastPathComponent().path, from: window)?
            .openFile(url.lastPathComponent, line: nil, column: nil)
    }
}
