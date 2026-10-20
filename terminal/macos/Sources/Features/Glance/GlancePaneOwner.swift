import AppKit
import GlanceCore

/// A window that can show the Glance side pane: a terminal window, or an editor tab. The pane follows `glanceDirectory`
/// (a terminal's focused folder, an editor's project root).
@MainActor
protocol GlancePaneOwner: AnyObject {
    var window: NSWindow? { get }
    var glancePaneOpen: Bool { get set }
    /// Where the pane shows: a sidebar or a floating orb; nil until the window is measured.
    var glancePlacement: PaneLayout.Placement? { get }
    var glanceDirectory: String? { get }
}

extension BaseTerminalController: GlancePaneOwner {
    var glanceDirectory: String? { focusedSurface?.pwd }
}
