import AppKit
import GlanceCore
import Observation
import SwiftUI

/// The pill beside the cursor while Claude turns a sentence, or a failed command, into a command (spec "S5"), and after:
/// the command sits on the line marked as Claude's suggestion, never run. Esc puts the line back as it was (the sentence
/// typed, or an empty prompt); editing the line keeps the edit and the pill goes.
@MainActor
final class SuggestionBadge: ShellOverlay {
    enum State: Equatable {
        case writing
        case suggested(risky: Bool)
        case failed(String)
    }

    private(set) weak var session: ShellSession?
    private(set) weak var surface: Ghostty.SurfaceView?
    private let popup: ShellPopup
    private let model: SuggestionBadgeModel
    var window: NSWindow? { popup.parent }

    /// The line to bring back on Esc.
    let original: String
    /// What the line holds now that the pill vouches for: the original while Claude writes, then its command.
    private(set) var expected: String
    var onDismiss: (() -> Void)?
    private var closed = false

    init(session: ShellSession, surface: Ghostty.SurfaceView, original: String) {
        self.session = session
        self.surface = surface
        self.original = original
        expected = original
        model = SuggestionBadgeModel(fix: original.isEmpty)
        popup = ShellPopup(SuggestionBadgeView(model: model).padding(12))
    }

    var state: State { model.state }

    func show() {
        guard let surface, let window = surface.window, let cursor = surface.cursorScreenRect else { return }
        let size = NSSize(width: model.width + 24, height: 50)
        // Just right of the line's end, the pill (26pt, inside a 12pt margin) centred on the prompt's row. A line that
        // runs close to the window's edge puts it on the row above instead, at the right, so it never covers the text.
        let x = cursor.maxX + 6
        if x + size.width - 12 > window.frame.maxX - 8 {
            let anchor = NSRect(x: window.frame.maxX - size.width + 12 - 16, y: cursor.minY, width: 1, height: cursor.height)
            popup.show(over: window, anchor: anchor, size: size, leading: 12, margin: 12, preferAbove: true)
        } else {
            popup.show(over: window, anchor: NSRect(x: x, y: cursor.midY + 15, width: 1, height: 1), size: size,
                       leading: 12, margin: 12)
        }
    }

    /// The command is on its way to the line: the pill is placed when the line arrives (`lineChanged`), since the cursor
    /// is still where the sentence ended until then.
    func suggested(_ command: String, risky: Bool) {
        expected = command
        model.state = .suggested(risky: risky)
    }

    func failed(_ message: String) {
        model.state = .failed(message)
        show()
    }

    /// The line is what the pill vouches for; anything else is the user's edit.
    func lineChanged(_ text: String, cursor: Int) -> Bool {
        guard text == expected else { return false }
        // Beside the line's new end, once the terminal has drawn it.
        if case .suggested = model.state {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                MainActor.assumeIsolated { if let self, !self.closed { self.show() } }
            }
        }
        return true
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard event.keyCode == 53 else { return false }  // esc
        onDismiss?()
        return true
    }

    func close() {
        closed = true
        popup.close()
    }
}

@MainActor
@Observable
final class SuggestionBadgeModel {
    var state: SuggestionBadge.State = .writing
    let fix: Bool

    init(fix: Bool) { self.fix = fix }

    var title: String {
        switch state {
        case .writing: fix ? "Claude is writing a fix" : "Claude is writing a command"
        case .suggested(let risky): risky ? "Suggested by Claude · check before running" : "Suggested by Claude"
        case .failed(let message): message
        }
    }

    var key: String {
        switch state {
        case .writing: "esc"
        case .suggested: "esc"
        case .failed: ""
        }
    }

    /// An estimate of the pill's width, so its window fits it.
    var width: CGFloat { min(420, CGFloat(title.count) * 6.6 + 78) }
}

struct SuggestionBadgeView: View {
    let model: SuggestionBadgeModel

    var body: some View {
        HStack(spacing: 7) {
            CoralDot()
            Text(model.title)
                .font(.studio(12, .semibold))
                .foregroundStyle(StudioColors.ink)
                .lineLimit(1)
            if !model.key.isEmpty {
                Text(model.key)
                    .font(.studioMono(10.5, .medium))
                    .foregroundStyle(StudioColors.body)
                    .padding(.horizontal, 4)
                    .frame(minHeight: 16)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(StudioColors.chip))
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 7)
        .frame(height: 26)
        .modifier(WritingGlow(active: model.state == .writing))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.title)
    }
}

/// The one light running round the pill's border while Claude writes (the answer panel's), and none after.
private struct WritingGlow: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.modifier(GlowRing())
        } else {
            content
                .background(Capsule().fill(StudioColors.solid))
                .overlay(Capsule().strokeBorder(StudioColors.muted.opacity(0.35), lineWidth: 1))
        }
    }
}
