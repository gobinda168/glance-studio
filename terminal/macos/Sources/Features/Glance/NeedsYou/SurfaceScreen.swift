import AppKit
import GhosttyKit
import GlanceCore

/// A split's visible text and keys pressed into it, for "Claude needs you". Never call `visibleText` from inside a
/// Ghostty callback (the surface lock is held there): hop to the main queue first.
@MainActor
enum SurfaceScreen {
    /// The viewport's text, read now (not `cachedVisibleContents`, which can be half a second old).
    static func visibleText(_ view: Ghostty.SurfaceView) -> String? {
        guard let surface = view.surface else { return nil }
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }

    /// Presses `keys` in order, a little apart (longer after pasted text, as `OrbChannelStudio.type` waits). Returns
    /// how long after now the last key goes, at the latest. `beforeEnter`, when given, is asked just before Enter and can
    /// make it wait or stop it; `finished` says whether they all went. Without it the keys go as they always have.
    @discardableResult
    static func send(_ keys: [PromptKey], to view: Ghostty.SurfaceView, beforeEnter: (() -> BoardPromptGuard.EnterGate)? = nil,
                     finished: ((Bool) -> Void)? = nil) -> TimeInterval {
        guard let model = view.surfaceModel else {
            finished?(false)
            return 0
        }
        var delay = 0.0
        var stopped = false
        for (index, key) in keys.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    guard !stopped else { return }
                    if key == .enter, let beforeEnter {
                        // Keys are timed from the start, so one behind an Enter that waits would overtake it.
                        guard index == keys.count - 1 else {
                            stopped = true
                            finished?(false)
                            return
                        }
                        pressEnter(model, when: beforeEnter, finished: finished)
                        return
                    }
                    defer { if index == keys.count - 1 { finished?(true) } }
                    switch key {
                    case .text(let text): model.sendText(text)
                    case .up: press(model, .arrowUp)
                    case .down: press(model, .arrowDown)
                    case .enter: press(model, .enter)
                    case .escape: press(model, .escape)
                    case .tab: press(model, .tab)
                    case .space: press(model, .space, text: " ")
                    }
                }
            }
            if case .text = key { delay += 0.15 } else { delay += 0.06 }
        }
        return beforeEnter == nil ? delay : delay + BoardPromptGuard.enterPatience
    }

    private static func pressEnter(_ model: Ghostty.Surface, when gate: @escaping () -> BoardPromptGuard.EnterGate,
                                   finished: ((Bool) -> Void)?) {
        switch gate() {
        case .press:
            press(model, .enter)
            finished?(true)
        case .wait:
            DispatchQueue.main.asyncAfter(deadline: .now() + BoardPromptGuard.enterRetry) {
                MainActor.assumeIsolated { pressEnter(model, when: gate, finished: finished) }
            }
        case .refuse:
            finished?(false)
        }
    }

    /// Shift+Tab, which cycles Claude Code's permission mode.
    static func pressShiftTab(_ view: Ghostty.SurfaceView) {
        guard let model = view.surfaceModel else { return }
        model.sendKeyEvent(Ghostty.Input.KeyEvent(key: .tab, action: .press, mods: [.shift]))
        model.sendKeyEvent(Ghostty.Input.KeyEvent(key: .tab, action: .release, mods: [.shift]))
    }

    private static func press(_ model: Ghostty.Surface, _ key: Ghostty.Input.Key, text: String? = nil) {
        model.sendKeyEvent(Ghostty.Input.KeyEvent(key: key, action: .press, text: text))
        model.sendKeyEvent(Ghostty.Input.KeyEvent(key: key, action: .release))
    }
}
