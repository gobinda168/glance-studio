import GlanceCore
import SwiftUI

/// The side bar beside the activity strip: the selected mode's, flat on the design's bar colour, at the shared width.
/// Terminal and Editor list the window's tabs, Pull Requests the project's pull requests, Settings its sections and
/// search, the Browser its apps and tabs, Notifications the inbox, Automations and Agents their libraries, Tools its connectors.
struct StudioSidebarView: View {
    @ObservedObject private var modes = SidebarModeModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // A switch between side bars crossfades with a slight slide, the way System Settings changes panes. The old
        // one fades out where it stands; the new one eases in from a few points to the left.
        ZStack(alignment: .top) {
            sidebar
                .id(modes.mode)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .opacity.combined(with: .offset(x: -8)), removal: .opacity))
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: modes.mode)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(StudioColors.bar)
        .clipped()
        .overlay(alignment: .trailing) {
            Rectangle().fill(StudioColors.line).frame(width: 1)
        }
    }

    @ViewBuilder private var sidebar: some View {
        Group {
            switch modes.mode {
            case .terminal:
                TabSidebarView(content: .terminals)
            case .editor:
                TabSidebarView(content: .editors)
            case .pullRequests:
                PullRequestsSidebarView()
            case .settings:
                SettingsSidebarView()
            case .browser:
                BrowserSidebarView()
            case .journal:
                JournalSidebarView()
            case .usage:
                UsageSidebarView()
            case .notifications:
                NotificationsSidebarView()
            case .meetings:
                MeetingsSidebarView()
            case .captures:
                CapturesSidebarView()
            case .tickets:
                TicketsSidebarView()
            case .automations:
                AutomationsSidebarView()
            case .agents:
                AutomationsSidebarView(agents: true)
            case .tools:
                ToolsSidebarView()
            case .mods:
                ModsSidebarView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
