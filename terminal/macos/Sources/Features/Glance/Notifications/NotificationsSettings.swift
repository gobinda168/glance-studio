import GlanceCore
import GlanceKit
import SwiftUI

/// Notifications (spec 2026-10-09-notifications-design.md, "Settings"): which kinds nudge, the people and channels that
/// always do, Do not disturb, quiet in meetings, the sound, and how Slack and GitHub are doing.
struct NotificationsSettings: View {
    @ObservedObject private var hub = NotificationHub.shared
    @ObservedObject private var slack = SlackMCPProbe.shared
    @State private var vipInput = ""
    @FocusState private var vipFocused: Bool

    private static let sources: [Notice.Source] = [.slack, .github, .claude]

    var body: some View {
        SettingsGroup(title: "Nudges") {
            SettingsRow(id: "notifications.nudge", name: "Nudge me for",
                        detail: "A nudge drops in at the top of the screen when one of these arrives. Everything "
                            + "still lands in Notifications either way.",
                        stacked: true) {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Self.sources, id: \.self) { source in
                        VStack(alignment: .leading, spacing: 8) {
                            Caption(source.title)
                            ForEach(Notice.Kind.kinds(of: source), id: \.self) { kind in kindRow(kind) }
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Caption(Notice.Source.meeting.title)
                        HStack(spacing: 4) {
                            Text("Meeting nudges are set in")
                                .font(.studio(12.5))
                                .foregroundStyle(StudioColors.muted)
                            Button { SettingsNavigation.shared.show(.meetings, focus: nil) } label: {
                                Text("Meetings ›")
                                    .font(.studio(12.5, .medium))
                                    .foregroundStyle(StudioColors.coral)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            SettingsRow(id: "notifications.vips", name: "Always nudge for",
                        detail: "People and channels that nudge you whatever the switches above say.",
                        stacked: true) {
                VStack(alignment: .leading, spacing: 10) {
                    if !hub.prefs.vips.isEmpty {
                        FlowChips(items: hub.prefs.vips) { vip in
                            hub.prefs.vips.removeAll { $0 == vip }
                        }
                    }
                    TextField("Add @person or #channel", text: $vipInput)
                        .textFieldStyle(.plain)
                        .font(.studioMono(12.5))
                        .foregroundStyle(StudioColors.ink)
                        .focused($vipFocused)
                        .onSubmit(addVIP)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.background))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(vipFocused ? StudioColors.coral : StudioColors.line3, lineWidth: 1))
                        .accessibilityLabel("Add a person or channel")
                }
            }
            SettingsRow(id: "notifications.dnd", name: "Do not disturb",
                        detail: "No nudges at all, except you still see everything in Notifications.") {
                SettingsSwitch(label: "Do not disturb",
                               isOn: Binding(get: { hub.prefs.doNotDisturb }, set: { hub.prefs.doNotDisturb = $0 }))
            }
            SettingsRow(id: "notifications.meetings", name: "Quiet during meetings",
                        detail: "No nudges while a meeting from your calendar is on.") {
                SettingsSwitch(label: "Quiet during meetings",
                               isOn: Binding(get: { hub.prefs.quietInMeetings },
                                             set: { hub.prefs.quietInMeetings = $0 }))
            }
            SettingsRow(id: "notifications.sound", name: "Play a sound", detail: "A soft chime when a nudge appears.") {
                SettingsSwitch(label: "Play a sound",
                               isOn: Binding(get: { hub.prefs.sound }, set: { hub.prefs.sound = $0 }))
            }
        }
        SettingsGroup(title: "Sources") {
            SettingsRow(id: "notifications.slack", name: "Slack replies", detail: slackDetail,
                        light: slack.checking ? nil : slack.status?.connected) {
                StudioButton(title: slack.status == nil ? "Check" : "Check again", busy: slack.checking,
                             enabled: !slack.checking, height: 26) { slack.check(force: true) }
            }
            SettingsRow(id: "notifications.github", name: "GitHub", detail: githubDetail,
                        light: hub.status[.github] == .running) {
                StudioButton(title: "Check again", height: 26) { GitHubNoticeSource.shared.pollNow() }
            }
        }
    }

    private func kindRow(_ kind: Notice.Kind) -> some View {
        HStack(spacing: 12) {
            Text(kind.label)
                .font(.studio(13))
                .foregroundStyle(StudioColors.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            SettingsSwitch(label: kind.label,
                           isOn: Binding(get: { hub.prefs.nudges(kind) }, set: { hub.prefs.set(kind, $0) }))
        }
    }

    /// Replies to Slack go through Claude Code's Slack connector; this says whether it has one. Not checked until asked
    /// (Check, or the first Slack reply): a check starts a `claude` run.
    private var slackDetail: String {
        if slack.checking { return "Checking…" }
        guard let status = slack.status else {
            return "Replying to Slack from Glance uses Claude Code's Slack connector. Check whether it's connected."
        }
        if let problem = slack.problem { return problem }
        guard status.connected else {
            return "Not connected. In claude.ai open Settings → Connectors and connect Slack, then Check again."
        }
        let count = status.readTools.count + status.sendTools.count
        let tools = "\(count) tool\(count == 1 ? "" : "s")"
        return status.sendTools.isEmpty
            ? "Connected — \(tools), but none can post a reply."
            : "Connected — \(tools)."
    }

    private var githubDetail: String {
        switch hub.status[.github] ?? .off {
        case .running: "Running. Review requests, mentions and failed checks arrive as you work."
        case .paused(let reason): "Paused — \(reason)"
        case .off: "Off."
        }
    }

    private func addVIP() {
        let name = vipInput.trimmingCharacters(in: .whitespacesAndNewlines)
        vipInput = ""
        guard !name.isEmpty,
              !hub.prefs.vips.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        hub.prefs.vips.append(name)
    }
}

/// Removable chips for the people and channels, wrapping onto lines.
private struct FlowChips: View {
    let items: [String]
    let remove: (String) -> Void

    var body: some View {
        ChipLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                HStack(spacing: 6) {
                    Text(item)
                        .font(.studioMono(12))
                        .foregroundStyle(StudioColors.ink)
                    Button { remove(item) } label: {
                        StudioIcon(.close, size: 10).foregroundStyle(StudioColors.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(item)")
                }
                .padding(.leading, 10)
                .padding(.trailing, 8)
                .frame(height: 26)
                .background(Capsule().fill(StudioColors.hover))
                .overlay(Capsule().strokeBorder(StudioColors.line3, lineWidth: 1))
            }
        }
    }
}

/// Lays children left to right and wraps to a new line when the row is full.
private struct ChipLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let laid = arrange(width: bounds.width, subviews: subviews)
        for (subview, origin) in zip(subviews, laid.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + lineHeight), origins)
    }
}
