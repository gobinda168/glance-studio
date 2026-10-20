import AppKit
import GlanceCore

/// Which Settings section shows, in every window's Settings tab (spec 2026-10-08-settings-design.md, "Where Settings
/// lives"), remembered as `settingsSection` in Glance's defaults; and the row a search hit asked for, which the page
/// scrolls to and flashes once.
@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()

    private static let defaults = UserDefaults(suiteName: "dev.glance.Glance") ?? .standard

    /// A search hit's row. `serial` makes asking for the same row again a new request.
    struct Focus: Equatable {
        let row: String
        let serial: Int
    }

    @Published private(set) var section: SettingsSection
    @Published private(set) var focus: Focus?
    private var serial = 0

    private init() {
        section = SettingsSection(saved: Self.defaults.string(forKey: "settingsSection"))
    }

    /// A page has scrolled to the row: a page opened later doesn't flash it again.
    func focusHandled(_ focus: Focus) {
        if self.focus == focus { self.focus = nil }
    }

    /// Shows `section`; with `row`, the page scrolls to that row and flashes it.
    func show(_ section: SettingsSection, focus row: String? = nil) {
        if section != self.section {
            self.section = section
            Self.defaults.set(section.rawValue, forKey: "settingsSection")
        }
        if let row {
            serial += 1
            focus = Focus(row: row, serial: serial)
        }
    }
}
