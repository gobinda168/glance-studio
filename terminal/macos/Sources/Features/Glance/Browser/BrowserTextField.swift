import AppKit
import SwiftUI

/// The Browser's text fields (address, find): an AppKit field, so ↑ ↓ Return and Esc reach SwiftUI on macOS 13. A
/// click selects the whole text, as in Safari; `focusRequest` going up puts the caret here with everything selected.
struct BrowserTextField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int
    let placeholder: String
    var onFocus: (Bool) -> Void = { _ in }
    /// The user typed (not a change made from code).
    var onEdit: (String) -> Void = { _ in }
    var onSubmit: () -> Void
    var onCancel: () -> Void
    /// ↑ (-1) or ↓ (+1); true when handled.
    var onMove: (Int) -> Bool = { _ in false }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FocusTextField {
        let field = FocusTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont(name: "DMSans-9ptRegular", size: 13) ?? .systemFont(ofSize: 13)
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        field.onFocusChange = { focused in context.coordinator.parent.onFocus(focused) }
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: FocusTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
                field.currentEditor()?.selectAll(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: BrowserTextField
        var focusRequest = 0

        init(_ parent: BrowserTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ note: Notification) {
            let value = (note.object as? NSTextField)?.stringValue ?? ""
            parent.text = value
            parent.onEdit(value)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit(); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel(); return true
            case #selector(NSResponder.moveUp(_:)): return parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)): return parent.onMove(1)
            default: return false
            }
        }
    }
}

/// A text field that says when it gains and loses the caret, and selects all on a click into it.
final class FocusTextField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            onFocusChange?(true)
            DispatchQueue.main.async { [weak self] in self?.currentEditor()?.selectAll(nil) }
        }
        return became
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?(false)
    }
}
