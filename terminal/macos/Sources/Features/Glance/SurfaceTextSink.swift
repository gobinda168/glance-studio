import AppKit
import GhosttyKit
import GlanceKit

/// Dictated text goes straight into the focused terminal split, the way a paste does: no Accessibility permission,
/// no synthetic keystrokes.
@MainActor
final class SurfaceTextSink: TextSink {
    var canInsert: Bool { GlanceTerminalHost.shared.focusedSurfaceHandle != nil }
    var accessHint: String { "Click into a terminal first" }

    func requestAccess() {}

    func insert(_ text: String) -> TextInserter.Outcome {
        guard let surface = GlanceTerminalHost.shared.focusedSurfaceHandle else { return .failed }
        let length = text.utf8CString.count
        text.withCString { pointer in
            // The count includes the null terminator.
            ghostty_surface_text(surface, pointer, UInt(length - 1))
        }
        return .inserted
    }
}
