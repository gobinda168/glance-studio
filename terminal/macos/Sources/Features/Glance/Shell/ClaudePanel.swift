import AppKit
import GlanceCore
import GlanceKit
import Observation
import SwiftUI

/// Claude's answer above the prompt (spec "S5: Claude on demand", "The answer panel"): MASTER's inline box, a "Claude"
/// header with the coral dot and, while it thinks, the one glow ring on screen; then a short explanation and up to three
/// commands. ↑ ↓ choose, ⏎ Tab or → put the command on the line (it never runs), ⌘C copies, Esc closes and stops it.
@MainActor
final class ClaudePanel: ShellOverlay {
    private(set) weak var session: ShellSession?
    private(set) weak var surface: Ghostty.SurfaceView?
    let model: ClaudePanelModel
    private let popup: ShellPopup
    var onPick: ((String) -> Void)?
    var onClose: (() -> Void)?

    static let margin: CGFloat = 18
    var window: NSWindow? { popup.parent }

    /// The line when the panel opened: editing it means the user moved on, and the panel closes (so ⏎ is theirs).
    private let line: String

    init(session: ShellSession, surface: Ghostty.SurfaceView, question: String) {
        self.session = session
        self.surface = surface
        line = session.text
        model = ClaudePanelModel(question: question)
        popup = ShellPopup(ClaudePanelView(model: model).padding(Self.margin))
        model.onPick = { [weak self] index in
            self?.model.selected = index
            self?.pick()
        }
    }

    func show() {
        guard let surface, let window = surface.window, let cursor = surface.cursorScreenRect, let session else { return }
        let column = CGFloat(session.text.prefix(session.cursor).count) * max(surface.cellSize.width, 1)
        let start = max(cursor.minX - column, window.frame.minX + 8)
        popup.show(over: window, anchor: NSRect(x: start, y: cursor.minY, width: 1, height: cursor.height),
                   size: size(in: window), leading: Self.margin + 8, margin: Self.margin, preferAbove: true)
    }

    private func size(in window: NSWindow) -> NSSize {
        NSSize(width: HistoryListView.width(in: window) + Self.margin * 2, height: model.cardHeight + Self.margin * 2)
    }

    func answered(_ answer: TerminalAsk.Answer) {
        model.state = .answer(answer)
        if let window { popup.resize(to: size(in: window)) }
    }

    func failed(_ message: String) {
        model.state = .failed(message)
        if let window { popup.resize(to: size(in: window)) }
    }

    /// Editing the line closes it: the keys go back to being the shell's.
    func lineChanged(_ text: String, cursor: Int) -> Bool { text == line }

    func close() { popup.close() }

    private func pick() {
        guard let command = model.current?.command else { return }
        onPick?(command)
    }

    func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 126: model.move(-1)                  // ↑
        case 125: model.move(1)                   // ↓
        case 36, 76, 48, 124:                     // ⏎, enter, ⇥, →
            guard model.current != nil else { return false }
            pick()
        case 53: onClose?()                       // esc
        default: return false
        }
        return true
    }

    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.keyCode == 8, event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
              let command = model.current?.command else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        return true
    }
}

@MainActor
@Observable
final class ClaudePanelModel {
    enum State: Equatable {
        case thinking
        case answer(TerminalAsk.Answer)
        case failed(String)
    }

    let question: String
    var state: State = .thinking
    var selected = 0
    @ObservationIgnored var onPick: ((Int) -> Void)?

    init(question: String) { self.question = question }

    var commands: [TerminalAsk.Answer.Command] {
        if case .answer(let answer) = state { answer.commands } else { [] }
    }

    var current: TerminalAsk.Answer.Command? { commands.indices.contains(selected) ? commands[selected] : nil }

    func move(_ delta: Int) {
        guard !commands.isEmpty else { return }
        selected = min(max(selected + delta, 0), commands.count - 1)
    }

    var cardHeight: CGFloat {
        let header: CGFloat = 40, footer = HistoryListModel.footerHeight
        switch state {
        case .thinking: return header + 44 + footer
        case .failed: return header + 52 + footer
        case .answer(let answer):
            let lines = max(1, Int(ceil(Double(answer.explanation.count) / 88)))
            let rows = answer.commands.reduce(CGFloat(0)) { $0 + ($1.risky ? 44 : 30) }
            return header + CGFloat(lines) * 19 + 20 + rows + 8 + footer
        }
    }
}

struct ClaudePanelView: View {
    let model: ClaudePanelModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            header
            switch model.state {
            case .thinking:
                Text("Reading the folder, the last commands and the request…")
                    .font(.studio(12.5))
                    .foregroundStyle(StudioColors.muted)
                    .padding(.horizontal, 14)
                    .frame(height: 44, alignment: .leading)
            case .failed(let message):
                Text(message)
                    .font(.studio(12.5))
                    .foregroundStyle(StudioColors.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 52, alignment: .leading)
            case .answer(let answer):
                VStack(alignment: .leading, spacing: 8) {
                    if !answer.explanation.isEmpty {
                        Text(answer.explanation)
                            .font(.studio(13))
                            .foregroundStyle(StudioColors.ink)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(answer.commands.enumerated()), id: \.element.id) { index, command in
                            row(command, selected: index == model.selected)
                                .onTapGesture { model.onPick?(index) }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            Spacer(minLength: 0)
            ShellHints(hints: model.commands.isEmpty ? [("esc", "close")]
                       : [("⏎", "put on the line"), ("⌘C", "copy"), ("esc", "close")])
        }
        .frame(height: model.cardHeight)
        .background(shape.fill(StudioColors.solid))
        // The inline box's coral edge.
        .overlay(alignment: .leading) {
            Rectangle().fill(StudioColors.coral).frame(width: 3).clipShape(shape)
        }
        .shellCard(shape)
        .opacity(shown ? 1 : 0)
        .offset(y: shown || reduceMotion ? 0 : -4)
        .onAppear { withAnimation(.easeOut(duration: 0.16)) { shown = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Claude's answer")
    }

    private var header: some View {
        HStack(spacing: 8) {
            CoralDot()
            Text("Claude")
                .font(.studio(12.5, .semibold))
                .foregroundStyle(StudioColors.ink)
            Text(model.question)
                .font(.studio(12))
                .foregroundStyle(StudioColors.muted)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if model.state == .thinking {
                Text("Thinking")
                    .font(.studio(11.5, .semibold))
                    .foregroundStyle(StudioColors.ink)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .modifier(GlowRing())
                    .accessibilityLabel("Claude is thinking")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .overlay(alignment: .bottom) { Rectangle().fill(StudioColors.line2).frame(height: 1) }
    }

    private func row(_ command: TerminalAsk.Answer.Command, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Text(command.command)
                    .font(.studioMono(13))
                    .foregroundStyle(StudioColors.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Spacer(minLength: 10)
                Text(command.note)
                    .font(.studio(11.5))
                    .foregroundStyle(StudioColors.muted)
                    .lineLimit(1)
            }
            if command.risky {
                Text("Check before running")
                    .font(.studio(11, .semibold))
                    .foregroundStyle(StudioColors.amber)
                    .accessibilityLabel("Check this command before running it")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? StudioColors.selection : Color.clear))
        .overlay(alignment: .leading) {
            if selected { Capsule().fill(StudioColors.coral).frame(width: 2, height: 14).offset(x: 1) }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// After a failure no rule could fix: the Ask pill at the prompt (MASTER's reference: a quiet chip, the coral dot, its
/// ⌘ key, the one light running round its border). A click or ⌘I asks Claude; typing anything makes it go.
@MainActor
final class AskChip: ShellOverlay {
    private(set) weak var session: ShellSession?
    private(set) weak var surface: Ghostty.SurfaceView?
    private let popup: ShellPopup
    var window: NSWindow? { popup.parent }

    init(session: ShellSession, surface: Ghostty.SurfaceView, onAsk: @escaping () -> Void) {
        self.session = session
        self.surface = surface
        popup = ShellPopup(AskChipView(onAsk: onAsk).padding(12))
    }

    func show() {
        guard let surface, let window = surface.window, let cursor = surface.cursorScreenRect else { return }
        // Just right of the cursor, its pill (26pt, inside a 12pt margin) centred on the prompt's line: placed "below" an
        // anchor 15pt above the line's middle.
        let anchor = NSRect(x: cursor.maxX + 6, y: cursor.midY + 15, width: 1, height: 1)
        popup.show(over: window, anchor: anchor, size: NSSize(width: 150, height: 50), leading: 12, margin: 12)
    }

    func lineChanged(_ text: String, cursor: Int) -> Bool { text.isEmpty }
    func handleKey(_ event: NSEvent) -> Bool { false }
    func close() { popup.close() }
}

struct AskChipView: View {
    let onAsk: () -> Void

    var body: some View {
        Button(action: onAsk) {
            HStack(spacing: 7) {
                CoralDot()
                Text("Ask Claude")
                    .font(.studio(12, .semibold))
                    .foregroundStyle(StudioColors.ink)
                Text("⌘I")
                    .font(.studioMono(10.5, .medium))
                    .foregroundStyle(StudioColors.body)
                    .padding(.horizontal, 4)
                    .frame(minHeight: 16)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(StudioColors.chip))
            }
            .padding(.leading, 9)
            .padding(.trailing, 7)
            .frame(height: 26)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(GlowRing())
        .help("Ask Claude what went wrong (⌘I)")
        .accessibilityLabel("Ask Claude what went wrong")
    }
}
