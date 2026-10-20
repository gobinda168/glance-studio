import GlanceCore
import GlanceKit
import SwiftUI

extension View {
    /// The activity strip at the window's left edge, beside this content (the tab's side bar, content and Glance
    /// pane), and the update toast at the window's bottom left.
    func activityStrip() -> some View {
        HStack(spacing: 0) {
            ActivityStripView()
            self
        }
        // The update toast: at the bottom left beside the strip, over the side bar when it's open.
        .overlay(alignment: .bottomLeading) {
            if let updates = (NSApp.delegate as? AppDelegate)?.updateViewModel {
                UpdateToast(model: updates)
                    .padding(.leading, ActivityStripView.width + 12)
                    .padding(.bottom, 12)
            }
        }
    }
}

/// The icon strip at the left edge of every window, as the PR Management canvas draws it (spec
/// 2026-10-07-pr-manager-design.md): its line icons in its order (those this build has, see StudioFeatures), the
/// selected one lit while its side bar is open, Pull requests with the number waiting on you, Agents with a dot while
/// Claude works on something Glance started, and Notifications and Settings at the bottom. Journal opens its tab, like
/// Settings. It stays while the side bar is closed; a click on any icon opens it on that mode.
struct ActivityStripView: View {
    static let width: CGFloat = 48

    @ObservedObject private var modes = SidebarModeModel.shared
    @ObservedObject private var sidebar = TabSidebarModel.shared
    @ObservedObject private var pullRequests = PullRequestsModel.shared
    @ObservedObject private var agents = AgentsActivity.shared
    @ObservedObject private var browser = BrowserApps.shared
    @ObservedObject private var features = StudioFeatures.shared
    @ObservedObject private var notices = NotificationHub.shared
    @ObservedObject private var recorder = MeetingRecorder.shared
    /// The strip's window: Settings opens as a tab there.
    @State private var window: NSWindow?
    /// The lit icon's plate slides from one icon to the next (`matchedGeometryEffect`).
    @Namespace private var plate
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The lit mode: the selected icon while the side bar is open.
    private var lit: SidebarMode? { sidebar.isOpen ? modes.mode : nil }

    var body: some View {
        VStack(spacing: 4) {
            ForEach(SidebarMode.stripModes(enabled: features.enabled), id: \.self) { modeButton($0) }
            Spacer(minLength: 8)
            // Notifications sits at the bottom, above Settings.
            ForEach(SidebarMode.stripBottomModes(enabled: features.enabled), id: \.self) { modeButton($0) }
            // Settings: its side bar and the window's Settings tab; a second click hides the side bar.
            StripButton(icon: .settings, label: SidebarMode.settings.title,
                        isSelected: sidebar.isOpen && modes.mode == .settings, badge: 0, working: false, plate: plate) {
                modes.choose(.settings, in: window)
            }
        }
        .animation(GlassChrome.move(reduceMotion), value: lit)
        .padding(.vertical, 8)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(StudioColors.bar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(StudioColors.line).frame(width: 1)
        }
        // Every window shows the strip, whichever side bar is up: follow its tab group from here.
        .background(WindowAccessor { found in
            if let found { sidebar.watch(found) }
            window = found
        })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Activity Bar")
    }

    private func modeButton(_ mode: SidebarMode) -> some View {
        StripButton(
            icon: mode.icon,
            label: mode.isBuilt ? mode.title : "\(mode.title) (coming soon)",
            isSelected: sidebar.isOpen && modes.mode == mode,
            badge: mode == .pullRequests ? pullRequests.badge : mode == .browser ? browser.stripBadge
                : mode == .notifications ? notices.book.badge : 0,
            working: mode == .agents && agents.isRunning,
            unread: mode == .browser && browser.stripUnread,
            recording: mode == .meetings && recorder.isRecording,
            plate: plate
        ) {
            // Its last tab in this window, else its fallback (Journal, Meetings, Usage: their tab); a second click on
            // the lit icon hides the side bar.
            modes.choose(mode, in: window)
        }
    }
}

/// One of the strip's icons, the canvas's `.ib` at 40 pt: a 20 pt line icon, the selection's tint and a coral edge
/// inside its left side when selected, a soft square under the pointer, and the coral count or dot at its corner.
private struct StripButton: View {
    let icon: StudioIcons.Name
    let label: String
    let isSelected: Bool
    let badge: Int
    /// Claude is working on something Glance started (the Agents dot).
    let working: Bool
    /// Something is unread in Chats, with no mentions (the muted dot).
    var unread = false
    /// A meeting is being recorded (Meetings' red dot).
    var recording = false
    let plate: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Button(action: action) {
            StudioIcon(icon, size: 20)
                .foregroundStyle(isSelected || hovering ? StudioColors.ink : StudioColors.muted)
                .frame(width: 40, height: 40)
                .background(shape.fill(hovering && !isSelected ? StudioColors.hover : Color.clear))
                .background {
                    // The lit plate and its coral edge belong to whichever icon is selected: they slide between icons.
                    if isSelected {
                        shape.fill(StudioColors.selection)
                            .overlay(alignment: .leading) { Rectangle().fill(StudioColors.coral).frame(width: 2) }
                            .clipShape(shape)
                            .matchedGeometryEffect(id: "stripPlate", in: plate)
                    }
                }
                .clipShape(shape)
                .overlay(alignment: .topTrailing) { corner }
                .contentShape(shape)
        }
        .buttonStyle(StripPressStyle())
        .onHover { hovering = $0 }
        .animation(GlassChrome.fade, value: hovering)
        .animation(GlassChrome.fade, value: isSelected)
        .help(label)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The count (Pull requests) or the dot (Agents), where the canvas pins them inside the button.
    @ViewBuilder private var corner: some View {
        if badge > 0 {
            Text(badge > 99 ? "99+" : "\(badge)")
                .font(.studio(9.5, .bold))
                .foregroundStyle(StudioColors.onCoral)
                .padding(.horizontal, 4)
                .frame(minWidth: 15, minHeight: 15)
                .background(Capsule().fill(StudioColors.coral))
                .padding(.top, 4)
                .padding(.trailing, 3)
                .accessibilityHidden(true)
        } else if recording {
            Circle()
                .fill(GlanceColor.critical)
                .frame(width: 7, height: 7)
                .padding(.top, 7)
                .padding(.trailing, 7)
                .accessibilityHidden(true)
        } else if working {
            CoralDot(size: 7)
                .padding(.top, 7)
                .padding(.trailing, 7)
        } else if unread {
            Circle()
                .fill(StudioColors.muted)
                .frame(width: 6, height: 6)
                .padding(.top, 7)
                .padding(.trailing, 7)
                .accessibilityHidden(true)
        }
    }

    private var accessibilityText: String {
        if badge > 0 { return "\(label), \(badge) waiting on you" }
        if recording { return "\(label), recording" }
        if working { return "\(label), Claude is working" }
        if unread { return "\(label), unread" }
        return label
    }
}

/// An icon gives a little under the press and springs back, the way Dock and toolbar buttons do.
private struct StripPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.9 : 1)
            .animation(GlassChrome.press, value: configuration.isPressed)
    }
}
