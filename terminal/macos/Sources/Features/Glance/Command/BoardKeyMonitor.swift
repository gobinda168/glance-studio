import AppKit
import GlanceCore

/// The board's keys (the legend's j k n r 1-4 and ↵), as a local monitor that lives only while the board is on screen.
/// A key moves the selection, opens a card or opens its reply box: none sends anything to a terminal.
@MainActor
final class BoardKeyMonitor: ObservableObject {
    nonisolated(unsafe) private var token: Any?
    private weak var window: NSWindow?

    func start(window: NSWindow?) {
        self.window = window
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) ?? false } ? nil : event
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }

    deinit { if let token { NSEvent.removeMonitor(token) } }

    /// Only with this tab in front, no modifiers, and the board itself holding the keyboard (`BoardKeys.command`).
    private func handle(_ event: NSEvent) -> Bool {
        guard let window else { return false }
        let model = BoardModel.shared
        let boardIsKey = event.window === window && window.isKeyWindow
        // The card with the reply box left the board or can't take a reply now. This key isn't a command either.
        if boardIsKey, let open = model.reply, !model.visible.contains(where: { $0.id == open && BoardActions.canReply($0) }) {
            model.reply = nil
            return false
        }
        let context = BoardKeys.Context(boardIsKey: boardIsKey,
                                        plain: event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                                        focus: focus(in: window), replyOpen: model.reply != nil,
                                        fullKeyboardAccess: NSApp.isFullKeyboardAccessEnabled)
        guard let command = BoardKeys.command(characters: event.charactersIgnoringModifiers, keyCode: event.keyCode, in: context) else {
            return false
        }
        let selected = model.visible.first { $0.id == model.selection }
        switch command {
        case .move(let action):
            model.selection = BoardKeys.selection(for: action, current: model.selection, cards: model.visible)
        case .open:
            guard let selected else { return false }
            BoardActions.open(selected, from: window)
        case .startReply:
            guard let selected, BoardActions.canReply(selected) else { return false }
            model.reply = selected.id
        case .closeReply:
            model.reply = nil
        }
        return true
    }

    /// The board has the keyboard only with nothing focused in the tab: the window or its root view as first responder.
    /// Anything deeper (the Glance pane's web view, a terminal surface, the side bar's list, another field) is someone
    /// else's, by not being on this short list rather than by being named.
    private func focus(in window: NSWindow) -> BoardKeys.Focus {
        let responder = window.firstResponder
        if responder === window || responder === window.contentView { return .page }
        if responder is NSText, BoardModel.shared.replyHasKeyboard { return .replyBox }
        return .elsewhere
    }
}
