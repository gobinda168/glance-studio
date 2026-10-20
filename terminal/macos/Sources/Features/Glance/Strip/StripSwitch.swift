import AppKit
import GlanceCore

/// A strip click's content (spec 2026-10-11-strip-switching-design.md §1): the item's last tab in the window, else
/// its fallback.
@MainActor
enum StripSwitch {
    static func go(to mode: SidebarMode, in window: NSWindow) {
        // Automations, Agents and Mods always go to their full-width library (spec
        // 2026-10-14-fullwidth-libraries-design.md).
        switch mode {
        case .automations, .agents:
            _ = AutomationsLibraryTabController.open(agents: mode == .agents, from: window)
            return
        case .mods:
            _ = ModsTabController.open(library: true, from: window)
            return
        default: break
        }
        if let tab = TabSidebarModel.shared.lastTab(for: mode, near: window) {
            // As the side bar's tab rows do: selecting the tab brings it forward, and ordering it front again in
            // native full screen sent the whole window off its Space (to the Dock, as the user saw it).
            tab.tabGroup?.selectedWindow = tab
            tab.makeKey()
            return
        }
        switch mode {
        case .terminal: TabSidebarModel.shared.newTab(near: window)
        case .editor: _ = EditorStartTab.open(from: window)
        case .browser: _ = BrowserTabController.open(url: nil, from: window)
        case .captures: _ = CapturesTabController.open(from: window)
        case .tickets: _ = TicketsTabController.open(from: window)
        case .journal: _ = JournalTabController.open(from: window)
        case .meetings: _ = MeetingsTabController.open(from: window)
        case .usage: _ = UsageTabController.open(from: window)
        case .notifications: _ = NotificationsTabController.open(from: window)
        case .settings: _ = SettingsTabController.open(from: window)
        case .pullRequests, .tools: break // the side bar only
        case .automations, .agents, .mods: break // above
        }
    }
}
