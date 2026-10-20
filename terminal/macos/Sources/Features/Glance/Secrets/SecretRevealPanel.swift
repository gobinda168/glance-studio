import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// Shows a revealed value for 15 seconds, in a small panel of its own and nowhere else. Why so fenced:
/// - Claude's processes run under Studio and may inherit its Screen Recording grant, so the panel is
///   `sharingType = .none` (left out of screenshots and screen capture where macOS honours it).
/// - Accessibility clients (which Claude could also drive) must not read it: the value is drawn by a plain `NSView`
///   that isn't an accessibility element, has no children, no value and no selection; there is no text field,
///   nothing to select or copy, and it never goes onto a pasteboard, into a field or into a log.
/// - It closes after 15 s (a timer on the common run-loop modes, so a modal panel or a menu can't hold it open), on
///   Esc or its button, when Studio stops being active, when the secrets lock, and when the editor closes or opens
///   its folder panel; closing releases the panel's content, the only holder of the string.
@MainActor
final class SecretRevealPanel: ObservableObject {
    static let seconds: TimeInterval = 15
    static let shared = SecretRevealPanel()

    /// A value is on screen (the editor disables Add Folder… meanwhile).
    @Published private(set) var showing = false

    private var panel: RevealWindow?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    static func show(name: String, value: String) { shared.show(name: name, value: value) }

    static func close() { shared.close() }

    private func show(name: String, value: String) {
        close()
        let seconds = Self.seconds
        let parent = NSApp.keyWindow.map { $0.sheetParent ?? $0 }
        let deadline = Date().addingTimeInterval(seconds)
        let window = RevealWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered,
                                  defer: false)
        window.sharingType = .none
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Secret value"
        window.isMovableByWindowBackground = true
        window.isExcludedFromWindowsMenu = true
        window.hidesOnDeactivate = true
        window.level = .floating
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.isRestorable = false
        window.animationBehavior = .none
        // Clear: the SwiftUI content draws StudioColors.card, which follows a light/dark flip; a fixed NSColor wouldn't.
        window.backgroundColor = .clear
        window.isOpaque = false
        let host = NSHostingView(rootView: RevealContent(name: name, value: value, deadline: deadline) {
            SecretRevealPanel.close()
        })
        window.contentView = host
        window.setContentSize(host.fittingSize)
        if let parent {
            let frame = parent.frame
            window.setFrameTopLeftPoint(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.maxY - 120))
        } else {
            window.center()
        }
        window.onClose = { SecretRevealPanel.close() }
        panel = window
        showing = true
        window.makeKeyAndOrderFront(nil)
        // Added for the common modes: a scheduled timer only fires in the default mode, so a modal panel (NSOpenPanel's
        // runModal) or event tracking would keep the value up past 15 s.
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { SecretRevealPanel.close() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        observers = [SecretsService.didLock, NSApplication.didResignActiveNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { SecretRevealPanel.close() }
            }
        }
    }

    private func close() {
        timer?.invalidate()
        timer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if showing { showing = false }
        guard let window = panel else { return }
        panel = nil
        window.onClose = nil
        window.orderOut(nil)
        // Release the hosting view and with it the only copy of the value.
        window.contentView = nil
        window.close()
    }
}

/// The reveal panel's window: Esc closes it, and closing it from the title bar tidies up.
private final class RevealWindow: NSWindow {
    var onClose: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { onClose?() }

    override func close() {
        let onClose = self.onClose
        self.onClose = nil
        super.close()
        onClose?()
    }
}

private struct RevealContent: View {
    let name: String
    let value: String
    let deadline: Date
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                StudioIcon(.lock, size: 13).foregroundStyle(StudioColors.muted)
                Text(name)
                    .font(.studioMono(12.5, .semibold))
                    .foregroundStyle(StudioColors.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Closes in \(max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up)))) s")
                        .font(.studio(11))
                        .monospacedDigit()
                        .foregroundStyle(StudioColors.muted)
                }
            }
            ScrollView(.vertical) {
                RevealedValueView(value: value, width: Self.textWidth)
                    .frame(width: Self.textWidth, height: RevealedValueView.height(of: value, width: Self.textWidth),
                           alignment: .topLeading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .frame(height: min(220, RevealedValueView.height(of: value, width: Self.textWidth) + 20))
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.field))
            // Only the owner's eyes: no accessibility element for the value (see SecretRevealPanel).
            .accessibilityHidden(true)
            HStack(spacing: 8) {
                Text("Shown here only. It isn't copied anywhere.")
                    .font(.studio(11.5))
                    .foregroundStyle(StudioColors.muted)
                Spacer(minLength: 8)
                StudioButton(title: "Hide", style: .primary, height: 28, action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.top, 30)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .frame(width: 420)
        .background(StudioColors.card)
    }

    static let textWidth: CGFloat = 420 - 32 - 24
}

/// Draws the value; it is not text to AppKit or to Accessibility (no NSTextField or NSTextView, nothing selectable),
/// so it can't be read out, selected or copied.
private struct RevealedValueView: NSViewRepresentable {
    let value: String
    let width: CGFloat

    static func attributes() -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byCharWrapping
        style.lineSpacing = 2
        let font = NSFont(name: "JetBrainsMono-Regular", size: 12.5)
            ?? NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        return [.font: font, .paragraphStyle: style, .foregroundColor: NSColor.labelColor]
    }

    static func height(of value: String, width: CGFloat) -> CGFloat {
        let rect = (value as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                    options: [.usesLineFragmentOrigin], attributes: attributes())
        return ceil(rect.height)
    }

    func makeNSView(context: Context) -> ValueView {
        let view = ValueView()
        view.value = value
        return view
    }

    func updateNSView(_ view: ValueView, context: Context) {
        view.value = value
        view.needsDisplay = true
    }

    static func dismantleNSView(_ view: ValueView, coordinator: ()) { view.value = "" }

    final class ValueView: NSView {
        var value = ""

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            (value as NSString).draw(with: bounds, options: [.usesLineFragmentOrigin],
                                     attributes: RevealedValueView.attributes())
        }

        override func isAccessibilityElement() -> Bool { false }
        override func accessibilityChildren() -> [Any]? { [] }
        override func accessibilityValue() -> Any? { nil }
    }
}
