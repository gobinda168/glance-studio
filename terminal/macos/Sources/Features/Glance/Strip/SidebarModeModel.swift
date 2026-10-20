import AppKit
import GlanceCore

/// Which side bar the activity strip shows: shared by every window, like the side bar's open state and width, and
/// remembered (`sidebarMode` in Glance's defaults).
@MainActor
final class SidebarModeModel: ObservableObject {
    static let shared = SidebarModeModel()

    private static let defaults = UserDefaults(suiteName: "dev.glance.Glance") ?? .standard

    @Published private(set) var mode: SidebarMode

    private init() {
        mode = SidebarMode(saved: Self.defaults.string(forKey: "sidebarMode"), enabled: StudioFeatures.shared.enabled)
    }

    /// A feature went on or off in the Develop menu: a side bar whose feature is off gives way to Terminal's.
    func featuresChanged() {
        guard !mode.isShown(enabled: StudioFeatures.shared.enabled) else { return }
        mode = .terminal
        Self.defaults.set(mode.rawValue, forKey: "sidebarMode")
    }

    /// A click on the strip, as in VS Code: the selected icon hides the side bar; any other shows its side bar and
    /// its last tab in `window`, or its fallback (spec 2026-10-11-strip-switching-design.md §1). Automations, Agents
    /// and Mods open their library instead.
    func choose(_ mode: SidebarMode, in window: NSWindow?) {
        let sidebar = TabSidebarModel.shared
        // Automations, Agents and Mods go to their full-width library, which has no side bar to hide: the side bar's
        // open state is left as it is for the other tabs (spec 2026-10-14-fullwidth-libraries-design.md).
        if mode.opensLibrary {
            follow(mode)
            if let window { StripSwitch.go(to: mode, in: window) }
            return
        }
        if sidebar.isOpen && mode == self.mode {
            sidebar.isOpen = false
            return
        }
        show(mode)
        if let window { StripSwitch.go(to: mode, in: window) }
    }

    /// Shows `mode`'s side bar, opening the side bar if it's closed.
    func show(_ mode: SidebarMode) {
        if mode != self.mode {
            self.mode = mode
            Self.defaults.set(mode.rawValue, forKey: "sidebarMode")
        }
        TabSidebarModel.shared.isOpen = true
    }

    /// The front tab belongs to `mode` (spec 2026-10-11-strip-switching-design.md §2): its side bar becomes the shown
    /// one, without opening a closed side bar. A mode whose feature is off is never followed.
    func follow(_ mode: SidebarMode) {
        guard mode != self.mode, mode.isShown(enabled: StudioFeatures.shared.enabled) else { return }
        self.mode = mode
        Self.defaults.set(mode.rawValue, forKey: "sidebarMode")
    }
}
