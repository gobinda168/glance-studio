import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// First Light's window (spec 2026-10-10-first-light-onboarding-design.md): shown at the first launch instead of the
/// first terminal window, and from Help → Welcome to Glance Studio… any time after. A frameless-looking stage with no
/// title or traffic lights; Esc on the intro sets up later. When it finishes (or is skipped or closed) it records the
/// onboarding version, opens what the launch would have opened, and dissolves over it.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private static var current: OnboardingWindowController?

    static var isShowing: Bool { current != nil }

    private var model: OnboardingModel!
    private var onDone: (() -> Void)?
    private var ended = false

    /// Shows onboarding (or brings the open one forward). `onDone` runs once, as the window hands over.
    static func show(onDone: @escaping () -> Void) {
        if let current {
            current.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = OnboardingWindowController(onDone: onDone)
        current = controller
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(onDone: @escaping () -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Welcome to Glance Studio"
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenNone)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0.075, green: 0.071, blue: 0.067, alpha: 1)
                : NSColor(red: 0.957, green: 0.945, blue: 0.918, alpha: 1)
        }
        super.init(window: window)
        self.onDone = onDone
        window.delegate = self

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        model = OnboardingModel(reduceMotion: reduceMotion) { [weak self] in self?.end() }
        let root = OnboardingView(model: model, onLater: { [weak self] in self?.end() })
        window.contentView = NSHostingView(rootView: root)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Records this onboarding as seen, lets the launch carry on underneath, then fades the window out over it.
    private func end() {
        guard !ended else { return }
        ended = true
        Prefs.onboardingVersion = OnboardingFlow.version
        model.stop()
        let window = self.window
        let done = onDone
        onDone = nil
        done?()
        // The window the launch just opened came forward; stay above it while dissolving.
        window?.level = .floating
        window?.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = model.reduceMotion ? 0.16 : 0.5
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window?.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                window?.close()
                Self.current = nil
            }
        })
    }

    func windowWillClose(_ notification: Notification) {
        // ⌘W or the window going away any other way counts as "Set up later".
        if !ended {
            ended = true
            Prefs.onboardingVersion = OnboardingFlow.version
            model.stop()
            let done = onDone
            onDone = nil
            done?()
        }
        Self.current = nil
    }
}
