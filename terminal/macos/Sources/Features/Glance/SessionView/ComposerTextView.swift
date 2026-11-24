import AppKit
import SwiftUI
import UniformTypeIdentifiers
import GlanceCore
import GlanceKit

/// An `NSTextView` (SwiftUI's `TextEditor` can't report the caret) that grows from one to eight lines.
final class ComposerNSTextView: ImagePasteTextView {
    var surfaceID = ""
    var placeholder = "Ask Claude, or type / for commands"
    var dragTarget: ((Bool) -> Void)?
    var focusChanged: ((Bool) -> Void)?
    var sizeChanged: (() -> Void)?
    private var tookFocus = false

    // Keys go to the hidden terminal unless the composer holds the keyboard: take it when the view appears.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !tookFocus else { return }
        tookFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { focusChanged?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { focusChanged?(false) }
        return ok
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sizeChanged?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 14),
                                                         .foregroundColor: NSColor(StudioColors.muted)]
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard ImageIntake.hasImage(sender.draggingPasteboard) else { return super.draggingEntered(sender) }
        dragTarget?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        ImageIntake.hasImage(sender.draggingPasteboard) ? .copy : super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dragTarget?(false)
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        ImageIntake.hasImage(sender.draggingPasteboard) ? true : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dragTarget?(false)
        guard ImageIntake.hasImage(sender.draggingPasteboard), let urls = ImageIntake.urls(from: sender.draggingPasteboard) else {
            return super.performDragOperation(sender)
        }
        attachImages?(urls)
        return true
    }
}

struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var caret: Int
    @Binding var height: CGFloat
    @Binding var focused: Bool
    @Binding var dropTargeted: Bool
    let placeholder: String
    let surfaceID: String
    let menuOpen: Bool
    /// Bumped to take the keyboard.
    var focusRequest = 0
    let moveMenu: (Int) -> Void
    let acceptMenu: () -> Bool
    let submit: () -> Void
    let escape: () -> Void
    let attach: ([URL]) -> Void
    // Read so the field's colours are set again when the appearance changes.
    @Environment(\.colorScheme) private var colorScheme

    private static let maxLines: CGFloat = 8

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let view = ComposerNSTextView(usingTextLayoutManager: false)
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.textContainerInset = NSSize(width: 0, height: 2)
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        view.setAccessibilityLabel("Message to Claude")
        view.sizeChanged = { [weak coordinator = context.coordinator] in coordinator?.measure() }
        scroll.documentView = view
        context.coordinator.view = view
        configure(view, context.coordinator)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = context.coordinator.view else { return }
        context.coordinator.parent = self
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        configure(view, context.coordinator)
        if view.string != text { view.string = text }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
        let end = min(caret, (view.string as NSString).length)
        if NSMaxRange(view.selectedRange()) != end { view.setSelectedRange(NSRange(location: end, length: 0)) }
        view.needsDisplay = true
        context.coordinator.measure()
    }

    private func configure(_ view: ComposerNSTextView, _ coordinator: Coordinator) {
        view.font = NSFont(name: "DMSans-9ptRegular", size: 14) ?? NSFont(name: "DM Sans", size: 14) ?? .systemFont(ofSize: 14)
        view.textColor = NSColor(StudioColors.ink)
        view.insertionPointColor = NSColor(StudioColors.coral)
        view.surfaceID = surfaceID
        view.placeholder = placeholder
        view.attachImages = attach
        view.dragTarget = { [weak coordinator] on in coordinator?.parent.dropTargeted = on }
        view.focusChanged = { [weak coordinator] on in
            DispatchQueue.main.async { coordinator?.parent.focused = on }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var view: ComposerNSTextView?
        var updating = false
        var focusRequest = 0

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !updating, let view else { return }
            parent.text = view.string
            parent.caret = NSMaxRange(view.selectedRange())
            measure()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let view else { return }
            let end = NSMaxRange(view.selectedRange())
            if parent.caret != end { parent.caret = end }
        }

        /// One line at least, eight at most; the field scrolls beyond that.
        func measure() {
            guard let view, let layout = view.layoutManager, let container = view.textContainer else { return }
            layout.ensureLayout(for: container)
            let line = ceil(layout.defaultLineHeight(for: view.font ?? .systemFont(ofSize: 14)))
            let content = ceil(layout.usedRect(for: container).height) + view.textContainerInset.height * 2
            let next = min(max(content, line + 4), line * ComposerTextView.maxLines + 4)
            if abs(parent.height - next) > 0.5 {
                DispatchQueue.main.async { [weak self] in self?.parent.height = next }
            }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let shifted = NSApp.currentEvent.map { !$0.modifierFlags.intersection([.shift, .option]).isEmpty } ?? false
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if shifted { textView.insertNewlineIgnoringFieldEditor(nil); return true }
                if parent.menuOpen, parent.acceptMenu() { return true }
                parent.submit()
                return true
            case #selector(NSResponder.insertTab(_:)):
                return parent.menuOpen && parent.acceptMenu()
            case #selector(NSResponder.moveUp(_:)):
                guard parent.menuOpen else { return false }
                parent.moveMenu(-1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                guard parent.menuOpen else { return false }
                parent.moveMenu(1)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.escape()
                return true
            default:
                return false
            }
        }
    }
}
