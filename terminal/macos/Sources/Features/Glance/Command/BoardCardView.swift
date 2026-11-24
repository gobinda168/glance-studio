import GlanceCore
import SwiftUI

/// One session on the board (the replica's `.cx-card`): a tap opens it, one action sits at the top right, a waiting
/// session shows its prompt's buttons, and the reply box opens under it. It is `Equatable` and takes only values, so a
/// board of many cards redraws just the ones that changed: the page applies `.equatable()` and passes the focus and the
/// open reply box as plain flags rather than the model. The prompt block and the reply box are children that keep their
/// own state (the prompt is looked up when it changes, the typed text stays while the card redraws).
struct BoardCardView: View, Equatable {
    let card: BoardCard
    var focused = false
    /// The reply box is open on this card.
    var replying = false
    let window: NSWindow?
    @State private var hovering = false
    /// Whether `claude --resume` can find an ended session's folder: asked once per card, off the main thread, as it stats the disk.
    @State private var canResume = true

    private let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow
            whereRow
            BoardLiveLine(state: card.state)
                .padding(.top, 10)
            proofRow
                .padding(.top, 10)
            if !card.dots.isEmpty {
                BoardEnvironmentDotsView(environments: card.dots)
                    .padding(.top, 8)
            }
            if let gap = card.criticalGap {
                HStack(alignment: .top, spacing: 6) {
                    StudioIcon(.alert, size: 12)
                        .foregroundStyle(StudioColors.danger)
                        .padding(.top, 2)
                    Text(gap.text)
                        .font(.studio(12, .medium))
                        .foregroundStyle(StudioColors.ink)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Problem: \(gap.text)")
            }
            if card.capture != nil || card.pr != nil {
                captureRow
                    .padding(.top, 10)
            }
            if card.isWaiting {
                BoardPromptBlock(card: card, window: window)
            }
            if replying {
                BoardReplyBox(card: card, window: window)
                    .padding(.top, 10)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(StudioColors.card))
        .overlay(alignment: .leading) {
            if card.isWaiting { Rectangle().fill(StudioColors.amber).frame(width: 3) }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(stroke, lineWidth: focused ? 1.5 : 1))
        .contentShape(shape)
        // The buttons inside take their own taps first.
        .onTapGesture { open() }
        .onHover { hovering = $0 }
        .task(id: card.id) {
            guard case .nowhere = card.place else { return }
            let ended = card
            canResume = await Task.detached(priority: .utility) { BoardActions.resumeFolder(ended) != nil }.value
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(card.title), \(SessionBoard.lane(card).title)")
        .accessibilityAction(named: "Open") { open() }
    }

    private func open() {
        BoardModel.shared.selection = card.id
        BoardActions.open(card, from: window)
    }

    private var stroke: Color {
        if focused { return StudioColors.coral }
        if hovering { return StudioColors.line3 }
        return card.isWaiting ? StudioColors.amber.opacity(0.3) : StudioColors.line
    }

    // MARK: Rows

    private var titleRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(card.title)
                .font(.studio(13.5, .semibold))
                .foregroundStyle(card.isEnded ? StudioColors.body : StudioColors.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if case .external(let name) = card.place {
                BoardPlaceTag(name: name)
            }
            if card.mixed {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StudioColors.amber)
                    .help("More than one session in this worktree")
                    .accessibilityLabel("More than one session in this worktree")
            }
            action
        }
    }

    /// The one thing a card can do besides open: reply where Studio can type, the transcript where it can't (Warp), a
    /// resume once it has ended. Its space is kept while hidden so the title doesn't move on hover.
    @ViewBuilder private var action: some View {
        let revealed = hovering || focused || replying
        switch card.place {
        case .studio where BoardActions.canReply(card):
            BoardCardAction(icon: .reply, title: replying ? "Close the reply box" : "Reply (r)", revealed: revealed) {
                let model = BoardModel.shared
                model.selection = card.id
                model.reply = replying ? nil : card.id
            }
            .padding(.top, -4).padding(.trailing, -4)
        case .external:
            BoardCardAction(icon: .docs, title: "Open the transcript (read-only; it runs outside Studio)", revealed: revealed) {
                BoardModel.shared.selection = card.id
                BoardActions.openTranscript(card, from: window)
            }
            .padding(.top, -4).padding(.trailing, -4)
        case .nowhere:
            BoardCardAction(icon: .refresh, title: canResume ? "Resume (opens claude --resume in a new tab)" : "Its folder is gone",
                            revealed: revealed, enabled: canResume) {
                BoardModel.shared.selection = card.id
                BoardActions.resume(card, from: window)
            }
            .padding(.top, -4).padding(.trailing, -4)
        default:
            EmptyView()
        }
    }

    private var whereRow: some View {
        HStack(spacing: 5) {
            Text(card.project)
                .lineLimit(1)
                .layoutPriority(1)
            if let branch = card.branch {
                StudioIcon(.branch, size: 11)
                Text(branch)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.studioMono(11))
        .foregroundStyle(StudioColors.muted)
        .padding(.top, 5)
        .accessibilityElement(children: .combine)
    }

    private var proofRow: some View {
        HStack(spacing: 8) {
            ProofPillView(pill: card.pill)
            if card.pending > 0 {
                Text("\(card.pending) pending")
                    .font(.studio(11, .medium))
                    .foregroundStyle(StudioColors.muted)
            }
        }
    }

    private var captureRow: some View {
        HStack(spacing: 8) {
            if let capture = card.capture {
                BoardThumbnail(session: card.id, capture: capture)
                BoardCaption(capture: capture)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }
            if let pr = card.pr { BoardPRChip(pr: pr) }
        }
    }

    static func == (a: BoardCardView, b: BoardCardView) -> Bool {
        a.card == b.card && a.focused == b.focused && a.replying == b.replying && a.window === b.window
    }
}

// MARK: Acting

/// A 26 pt icon button at the card's top right (the replica's `.cx-act`).
private struct BoardCardAction: View {
    let icon: StudioIcons.Name
    let title: String
    let revealed: Bool
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            StudioIcon(icon, size: 13)
                .foregroundStyle(hovering && enabled ? StudioColors.ink : StudioColors.muted)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering && enabled ? StudioColors.hover : .clear))
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(revealed ? (enabled ? 1 : 0.45) : 0)
        .allowsHitTesting(revealed)
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

/// What a waiting session asks, what that approves, and its answers as buttons (the replica's `.cx-prompt`). It looks the
/// prompt up itself whenever prompts change, so the card around it need not redraw. A prompt the card can't show in full
/// or tie to this session (`BoardPromptGuard.offersAnswers`) opens the session instead; nothing here types except a click.
private struct BoardPromptBlock: View {
    let card: BoardCard
    let window: NSWindow?
    @State private var refresh = 0
    /// The prompt (by its tool call) whose answer really went, until it goes.
    @State private var answered: String?
    /// The keys of an answer are going: no second click until they have.
    @State private var answering = false
    /// Why the last answer didn't go. Its buttons stay away for a moment, so a second click can't land on a new prompt.
    @State private var problem: String?

    /// The keys went this long ago and the dialog is still up: they did nothing, so the buttons come back.
    private static let answeredLimit: Duration = .seconds(5)
    private static let problemLimit: Duration = .seconds(4)

    var body: some View {
        let _ = refresh
        // A VStack is here even with no prompt yet, so the subscription below always has something to sit on.
        VStack(spacing: 0) {
            if let prompt = BoardModel.shared.prompt(for: card) { block(prompt).padding(.top, 10) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .glancePromptsChanged)) { _ in refresh += 1 }
        .task(id: answered) {
            guard let call = answered else { return }
            try? await Task.sleep(for: Self.answeredLimit)
            if !Task.isCancelled, answered == call { answered = nil }
        }
        .task(id: problem) {
            guard let shown = problem else { return }
            try? await Task.sleep(for: Self.problemLimit)
            if !Task.isCancelled, problem == shown { problem = nil }
        }
    }

    private func block(_ prompt: PendingPrompt) -> some View {
        let offers = BoardPromptGuard.offersAnswers(prompt, session: card.id)
        return VStack(alignment: .leading, spacing: 8) {
            Text(BoardModel.promptTitle(prompt))
                .font(.studio(12, .medium))
                .foregroundStyle(StudioColors.ink)
                .fixedSize(horizontal: false, vertical: true)
            if answered == prompt.call.id {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                    Text("Answered").font(.studio(12, .medium))
                }
                .foregroundStyle(StudioColors.ok)
                .frame(minHeight: 26)
                .accessibilityElement(children: .combine)
            } else if let problem {
                Text(problem)
                    .font(.studio(11.5, .medium))
                    .foregroundStyle(StudioColors.danger)
                    .fixedSize(horizontal: false, vertical: true)
                openButton
            } else if offers {
                // A question can have no lines of its own, and an empty box would never be measured.
                if !prompt.screen.detail.isEmpty { BoardPromptDetail(prompt: prompt) }
                ForEach(prompt.screen.options, id: \.number) { option in
                    BoardPromptButton(title: option.label, note: option.note, primary: option.number == prompt.screen.options.first?.number,
                                      enabled: !answering) { pick(option, in: prompt) }
                }
            } else {
                openButton
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.amber.opacity(0.08)))
        // Reading it, or selecting the command, doesn't open the tab.
        .contentShape(Rectangle())
        .onTapGesture {}
        .accessibilityElement(children: .contain)
    }

    private var openButton: some View {
        BoardPromptButton(title: "Open to answer", primary: false) { BoardActions.open(card, from: window) }
    }

    /// A free-text option is typed in the terminal, so it opens the session rather than answering.
    private func pick(_ option: PromptOption, in prompt: PendingPrompt) {
        guard !answering else { return }
        PromptCardView.pick(option, answer: { answer in
            answering = true
            BoardActions.answer(prompt, answer, on: card) { result in
                answering = false
                switch result {
                case .sent: answered = prompt.call.id
                case .changed: problem = "This prompt changed. Open to answer."
                case .failed: problem = "Couldn't answer that prompt. Open to answer."
                }
                refresh += 1
            }
        }, showTerminal: { BoardActions.open(card, from: window) })
    }
}

/// What Yes approves: the dialog's own lines, never the book's idea of them, so a click can only approve what's drawn. It
/// scrolls once it's taller than a card should be. Then its foot fades and a line says so, so the end of a command isn't
/// missed: the scroller alone can stay hidden until scrolling.
private struct BoardPromptDetail: View {
    let prompt: PendingPrompt
    @State private var height: CGFloat = 0

    private static let limit: CGFloat = 180
    private static let fade: CGFloat = 24

    var body: some View {
        let cue = PromptDetail.overflowCue(height: height, limit: Self.limit, lines: prompt.screen.detail.count)
        VStack(alignment: .leading, spacing: 4) {
            ScrollView {
                PromptDetailView(detail: PromptDetail.onScreen(prompt), cap: .max, showAll: .constant(true), top: 0)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                    // Room past the end, so the last line can scroll clear of the fade.
                    .padding(.bottom, cue == nil ? 0 : Self.fade)
            }
            .scrollIndicators(.visible)
            .frame(height: height > 0 ? min(height, Self.limit) : Self.limit)
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: cue == nil ? 0 : Self.fade)
                }
            }
            if let cue {
                Text(cue)
                    .font(.studio(11.5, .medium))
                    .foregroundStyle(StudioColors.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One answer: at least 26 pt high and as tall as its words, as an option's text is its whole scope ("Yes, and don't ask
/// again for…"), so it wraps and is never cut. The first in coral (the replica's `.cx-opt`).
private struct BoardPromptButton: View {
    let title: String
    var note: String?
    let primary: Bool
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.studio(11.5, .semibold))
                    .foregroundStyle(primary ? StudioColors.onCoral : StudioColors.ink)
                if let note, !note.isEmpty {
                    Text(note)
                        .font(.studio(11))
                        .foregroundStyle(primary ? StudioColors.onCoral : StudioColors.muted)
                }
            }
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(primary ? StudioColors.coral : (hovering ? StudioColors.hover : .clear)))
            .overlay { if !primary { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(StudioColors.line3, lineWidth: 1) } }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .accessibilityLabel([title, note].compactMap { $0 }.joined(separator: " "))
    }
}

/// The reply box (the replica's `.cx-reply`). A failed send keeps the text and says so; Return sends, Esc closes. A reply
/// whose Return was held back may already be on the tab's line, so it can't be sent again until the tab has been opened.
private struct BoardReplyBox: View {
    let card: BoardCard
    let window: NSWindow?
    @State private var text: String
    @State private var failed = false
    /// Between the paste and its Return: a second send waits.
    @State private var sending = false
    @FocusState private var focused: Bool

    init(card: BoardCard, window: NSWindow?) {
        self.card = card
        self.window = window
        _text = State(initialValue: BoardActions.drafts[card.id] ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                TextField("Reply to this session…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.studio(13))
                    .foregroundStyle(StudioColors.ink)
                    .focused($focused)
                    .onSubmit(send)
                    .onExitCommand { BoardModel.shared.reply = nil }
                    .frame(height: 26)
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(StudioColors.onCoral)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(StudioColors.coral))
                        .opacity(trimmed.isEmpty ? 0.5 : 1)
                }
                .buttonStyle(.plain)
                .disabled(trimmed.isEmpty || sending || BoardActions.isHeld(card))
                .help("Send (↩)")
                .accessibilityLabel("Send reply")
            }
            .padding(.leading, 10).padding(4)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StudioColors.background))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(StudioColors.coral.opacity(0.5), lineWidth: 1))
            if BoardActions.isHeld(card) {
                Text("Couldn't reach that tab. Your text may be on its line, not sent: open the tab to finish it.")
                    .font(.studio(11.5, .medium))
                    .foregroundStyle(StudioColors.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 4)
                BoardPromptButton(title: "Open the tab", primary: false) { BoardActions.open(card, from: window) }
            } else if failed {
                Text("Couldn't reach that tab.")
                    .font(.studio(11.5, .medium))
                    .foregroundStyle(StudioColors.danger)
                    .padding(.leading, 4)
            }
        }
        // Clicking around the field doesn't open the tab under what's being typed.
        .contentShape(Rectangle())
        .onTapGesture {}
        // Not in the same pass that put the box on screen.
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onDisappear { BoardModel.shared.replyHasKeyboard = false }
        .onChange(of: focused) { BoardModel.shared.replyHasKeyboard = focused }
        .onChange(of: text) {
            failed = false
            BoardActions.drafts[card.id] = text.isEmpty ? nil : text
        }
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func send() {
        guard !trimmed.isEmpty, !sending else { return }
        sending = true
        BoardActions.send(text, to: card) { result in
            sending = false
            if result == .sent {
                text = ""
                BoardActions.drafts[card.id] = nil
                BoardModel.shared.reply = nil
            } else {
                failed = true
                // The tab may be gone, or `claude` no longer in it: let the board catch up.
                BoardModel.shared.rebuild()
            }
        }
    }
}

// MARK: Parts

/// "Warp": where a session runs that Studio can't type into. Lilac for Warp (the replica), plain for any other place.
private struct BoardPlaceTag: View {
    let name: String

    var body: some View {
        let tint = name.lowercased() == "warp" ? StudioColors.syntaxType : StudioColors.muted
        Text(name)
            .font(.studio(11, .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(name.lowercased() == "warp" ? tint.opacity(0.5) : StudioColors.line3, lineWidth: 1))
            .fixedSize()
            .padding(.top, 1)
            .help("Runs in \(name), so Studio can read it but not type into it")
    }
}

/// What the session is doing now, in a glyph and words (the replica's `.cx-live`).
private struct BoardLiveLine: View {
    let state: BoardState

    var body: some View {
        HStack(spacing: 7) {
            switch state {
            case .tool(let tool):
                Spinner(size: 11)
                Text(tool.detail.isEmpty ? tool.name : tool.detail)
                    .font(.studio(12, .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if let since = tool.since { BoardElapsed(since: since) }
            case .thinking:
                PulseDot()
                Text("Thinking").font(.studio(12, .medium))
            case .waiting:
                Circle().strokeBorder(StudioColors.amber, lineWidth: 2).frame(width: 8, height: 8)
                Text("Waiting on you").font(.studio(12, .medium))
            case .idle(let since):
                restingDot
                if let since { BoardAgo(prefix: "Idle · finished ", date: since) }
                else { Text("Ready for a first message").font(.studio(12, .medium)) }
            case .ended(let at):
                restingDot
                if let at { BoardAgo(prefix: "Ended · ", date: at) }
                else { Text("Ended").font(.studio(12, .medium)) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(tint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
    }

    private var restingDot: some View {
        Circle().fill(StudioColors.muted.opacity(0.7)).frame(width: 8, height: 8)
    }

    private var tint: Color {
        switch state {
        case .tool, .thinking: StudioColors.tealInk
        case .waiting: StudioColors.amber
        case .idle, .ended: StudioColors.muted
        }
    }

    private var spoken: String {
        switch state {
        case .tool(let tool): "Running \(tool.detail.isEmpty ? tool.name : tool.detail)"
        case .thinking: "Thinking"
        case .waiting: "Waiting on you"
        case .idle(let since): since.map { "Idle, finished \(BoardAgo.when($0))" } ?? "Ready for a first message"
        case .ended(let at): at.map { "Ended \(BoardAgo.when($0))" } ?? "Ended"
        }
    }
}

/// How long a tool has run, counting by the second as `m:ss`. Only this text redraws each second.
private struct BoardElapsed: View {
    let since: Date

    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(since)))
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                .font(.studioMono(11))
                .monospacedDigit()
                .foregroundStyle(StudioColors.muted)
        }
        .fixedSize()
        .accessibilityHidden(true)
    }
}

/// "12m" ago in the sidebar's words, kept fresh by the minute without redrawing the card.
private struct BoardAgo: View {
    let prefix: String
    let date: Date

    /// "12m ago", or "just now" rather than "now ago".
    static func when(_ date: Date, now: Date = Date()) -> String {
        let ago = ClaudeProjectFolder.ago(date, now: now)
        return ago == "now" ? "just now" : ago + " ago"
    }

    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(prefix + Self.when(date, now: context.date))
                .font(.studio(12, .medium))
                .lineLimit(1)
        }
    }
}

/// The capture's words (two lines) and, after them in the quiet face, where and how long ago.
private struct BoardCaption: View {
    let capture: ProofCapture

    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 30)) { context in
            let when = ClaudeProjectFolder.ago(capture.at, now: context.date)
            let detail = [capture.environment, when].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            (Text(capture.caption).font(.studio(12, .medium)).foregroundColor(StudioColors.body)
                + Text("  " + detail).font(.studio(11)).foregroundColor(StudioColors.muted))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The session's PR as a label, never a link: #482 and a glyph or word for its checks.
struct BoardPRChip: View {
    let pr: BoardPR

    var body: some View {
        HStack(spacing: 4) {
            StudioIcon(.pullRequest, size: 11)
            Text("#\(pr.number)" + (suffix.isEmpty ? "" : " " + suffix))
                .font(.studio(11, .medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pull request \(pr.number), \(spoken)")
        .help("Pull request #\(pr.number), \(spoken)")
    }

    private var suffix: String {
        if pr.merged { return "merged" }
        switch pr.checks {
        case .passing: return "✓"
        case .failing: return "✗"
        case .pending: return "●"
        case .empty: return ""
        }
    }

    private var spoken: String {
        if pr.merged { return "merged" }
        switch pr.checks {
        case .passing: return "checks passing"
        case .failing: return "checks failing"
        case .pending: return "checks running"
        case .empty: return "no checks"
        }
    }

    private var tint: Color {
        if pr.merged { return StudioColors.syntaxType }
        switch pr.checks {
        case .passing: return StudioColors.ok
        case .failing: return StudioColors.danger
        case .pending: return StudioColors.tealInk
        case .empty: return StudioColors.muted
        }
    }
}

/// One row per environment: its name, then a dot for each check. A circle passed, a square failed, a ring not run, so
/// the result never rests on colour alone; the help and the spoken label say it in words.
private struct BoardEnvironmentDotsView: View {
    let environments: [BoardEnvironmentDots]

    var body: some View {
        FlowRow(spacing: 12) {
            ForEach(Array(environments.enumerated()), id: \.offset) { _, environment in
                HStack(spacing: 3) {
                    Text(environment.environment)
                        .font(.studio(11, .medium))
                        .foregroundStyle(StudioColors.body)
                        .padding(.trailing, 4)
                    ForEach(Array(environment.checks.enumerated()), id: \.offset) { _, check in
                        BoardCheckDotView(result: check.result)
                    }
                }
                .help(summary(environment))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(summary(environment))
            }
        }
    }

    private func summary(_ environment: BoardEnvironmentDots) -> String {
        let checks = environment.checks.map { check -> String in
            switch check.result {
            case .passed: "\(check.name) passed"
            case .failed: "\(check.name) failed"
            case .notRun: "\(check.name) not run"
            }
        }
        return environment.environment + ": " + checks.joined(separator: ", ")
    }
}

private struct BoardCheckDotView: View {
    let result: BoardCheckDot.Result

    var body: some View {
        switch result {
        case .passed: Circle().fill(StudioColors.ok).frame(width: 6, height: 6)
        case .failed: RoundedRectangle(cornerRadius: 1).fill(StudioColors.danger).frame(width: 6, height: 6)
        case .notRun: Circle().strokeBorder(StudioColors.muted.opacity(0.6), lineWidth: 1).frame(width: 6, height: 6)
        }
    }
}
