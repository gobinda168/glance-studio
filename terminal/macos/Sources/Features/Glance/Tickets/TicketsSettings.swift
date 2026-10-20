import GlanceCore
import GlanceKit
import SwiftUI

/// Tickets (spec 2026-10-09-tickets-design.md, "Settings → Tickets"): the trackers Claude's connectors give, each with
/// its switch and the query that replaces its default set; the daily order's instructions; the morning card and the
/// check-in.
struct TicketsSettings: View {
    @ObservedObject private var service = TicketService.shared
    @ObservedObject private var probe = ConnectorProbe.shared
    @State private var showDefault = false

    var body: some View {
        trackers
        order
        status
        daily
    }

    private var trackers: some View {
        SettingsGroup(title: "Trackers") {
            SettingsRow(id: "tickets.trackers", name: "Trackers",
                        detail: "Tickets reads these through Claude's connectors, or straight from a Jira site Glance is "
                            + "signed in to. Without a query it lists what's assigned to you and what's unassigned in "
                            + "your current sprint.",
                        stacked: true) {
                VStack(alignment: .leading, spacing: 14) {
                    if service.allTrackers.isEmpty {
                        Text(emptyWords)
                            .font(.studio(12.5))
                            .foregroundStyle(StudioColors.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(service.allTrackers) { tracker in
                        TrackerSettingsRow(tracker: tracker)
                    }
                    HStack(spacing: 10) {
                        StudioButton(title: "Check again", icon: .refresh, style: .secondary, busy: probe.checking,
                                     height: 26) { probe.check(force: true) }
                        StudioButton(title: "Open Connectors", icon: .plug, style: .secondary, height: 26) {
                            ConnectorsSettings.open()
                        }
                        if probe.checking {
                            Text("Asking Claude Code which connectors it has…")
                                .font(.studio(12))
                                .foregroundStyle(StudioColors.muted)
                        }
                    }
                }
            }
        }
        .onAppear { probe.check() }
    }

    private var order: some View {
        SettingsGroup(title: "Daily order") {
            SettingsRow(id: "tickets.ranking", name: "How Claude orders your tickets",
                        detail: "Leave it empty for the default. Glance adds your tickets and the answer's format "
                            + "after what you write here.",
                        stacked: true) {
                VStack(alignment: .leading, spacing: 10) {
                    StudioTextEditor(placeholder: "Blockers and severity first, then priority, then due date…",
                                     text: $service.prefs.rankingPrompt, minHeight: 120, mono: true)
                    HStack(spacing: 10) {
                        StudioButton(title: "Reset to default", style: .secondary,
                                     enabled: !service.prefs.rankingPrompt.isEmpty, height: 26) {
                            service.prefs.rankingPrompt = ""
                        }
                        Button(showDefault ? "Hide the default" : "Show the default") {
                            withAnimation(.easeOut(duration: 0.16)) { showDefault.toggle() }
                        }
                        .buttonStyle(.plain)
                        .font(.studio(12.5, .medium))
                        .foregroundStyle(StudioColors.coralInk)
                    }
                    if showDefault {
                        Text(TicketRanking.defaultInstructions)
                            .font(.studioMono(11.5))
                            .foregroundStyle(StudioColors.body)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.field))
                    }
                }
            }
        }
    }

    /// A row per signal with the house segmented control (macOS's own segmented picker mis-sized the old stacked list
    /// and drew it over its neighbours). Signals that always ask offer only Nudge and Off.
    private var status: some View {
        SettingsGroup(title: "Status updates") {
            Text("When your work moves on. Auto moves the ticket itself (only forward, and only when there's exactly "
                + "one status to move to) and shows Undo. Nudge asks first with one click. Off ignores the signal.")
                .font(.studio(12))
                .foregroundStyle(StudioColors.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { Rectangle().fill(StudioColors.line2).frame(height: 1) }
                .id("tickets.status")
            ForEach(TicketSignal.allCases, id: \.self) { signal in
                SettingsRow(id: "tickets.status.\(signal.rawValue)", name: signal.title,
                            detail: signal == .stale ? "A ticket in progress with nothing seen for this long gets a "
                                + "\"Still on this?\" nudge." : nil) {
                    HStack(spacing: 12) {
                        if signal == .stale {
                            Stepper(value: $service.prefs.staleDays, in: 1...14) {
                                Text("\(service.prefs.staleDays) day\(service.prefs.staleDays == 1 ? "" : "s")")
                                    .font(.studioMono(12.5))
                                    .foregroundStyle(StudioColors.ink)
                            }
                            .fixedSize()
                        }
                        SegmentedTabs(items: modes(signal), selection: mode(signal))
                    }
                }
            }
            SettingsRow(id: "tickets.comment", name: "Comment on the ticket",
                        detail: "When Glance moves a ticket itself, it leaves a comment saying why (\"PR #412 merged — "
                            + "moved by Glance\").") {
                SettingsSwitch(label: "Comment on the ticket", isOn: $service.prefs.comment)
            }
        }
    }

    /// A signal's Auto / Nudge / Off; Auto turns into Nudge for the ones that always ask.
    private func mode(_ signal: TicketSignal) -> Binding<TicketPrefs.Mode> {
        Binding(get: { service.prefs.mode(signal) }, set: { service.prefs.set(signal, $0) })
    }

    private func modes(_ signal: TicketSignal) -> [SegmentItem<TicketPrefs.Mode>] {
        (signal.canAuto ? [.auto, .nudge, .off] : [.nudge, .off]).map {
            SegmentItem(value: $0, title: $0.rawValue.capitalized, count: nil)
        }
    }

    private var daily: some View {
        SettingsGroup(title: "Morning and check-in") {
            SettingsRow(id: "tickets.daily", name: "Your top 3 in the morning",
                        detail: "Claude reads your tickets, orders them, and a card from the orb shows the top 3.") {
                HStack(spacing: 10) {
                    Picker("When", selection: $service.prefs.morningFixed) {
                        Text("First activity after").tag(false)
                        Text("Exactly at").tag(true)
                    }
                    .labelsHidden()
                    .fixedSize()
                    DatePicker("Morning time", selection: time(\.morningMinutes), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.field)
                }
            }
            SettingsRow(id: "tickets.checkIn", name: "End-of-day check-in",
                        detail: "The tickets you touched today, each with the status Glance suggests.",
                        dimmed: !service.prefs.checkIn) {
                HStack(spacing: 10) {
                    DatePicker("Check-in time", selection: time(\.checkInMinutes), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .disabled(!service.prefs.checkIn)
                    SettingsSwitch(label: "End-of-day check-in", isOn: $service.prefs.checkIn)
                }
            }
            SettingsRow(id: "tickets.readAloud", name: "Read aloud",
                        detail: "The morning card is said in your voice from Settings → Voice.") {
                SettingsSwitch(label: "Read aloud", isOn: $service.prefs.readAloud)
            }
        }
    }

    /// A time of day for minutes after midnight.
    private func time(_ key: WritableKeyPath<TicketPrefs, Int>) -> Binding<Date> {
        Binding(
            get: {
                let minutes = service.prefs[keyPath: key]
                return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date())
                    ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                service.prefs[keyPath: key] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            })
    }

    private var emptyWords: String {
        if let error = probe.error { return error }
        if !probe.checked { return "Looking for your trackers…" }
        if let signIn = TrackerProbe.signInWords(probe.servers, then: "Check again") {
            return signIn.title + ". " + signIn.line
        }
        return "No tracker connected. Connect Jira through Claude or through Glance, or Linear or GitHub through "
            + "Claude, in Settings → Connectors."
    }
}

/// One tracker: its name and server, its switch, and its query (saved when the field is left or ↩ is pressed).
private struct TrackerSettingsRow: View {
    let tracker: Tracker
    @ObservedObject private var service = TicketService.shared
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                StatusLight(on: true)
                Text(tracker.name)
                    .font(.studio(13, .semibold))
                    .foregroundStyle(StudioColors.ink)
                Text(tracker.kind == .glance ? "via Glance" : "via Claude")
                    .font(.studio(11.5, .medium))
                    .foregroundStyle(StudioColors.body)
                if tracker.kind == .claude {
                    Text(tracker.server)
                        .font(.studioMono(11.5))
                        .foregroundStyle(StudioColors.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                SettingsSwitch(label: "Read \(tracker.name)",
                               isOn: Binding(get: { !service.prefs.trackersOff.contains(tracker.server) },
                                             set: { on in
                                                 if on { service.prefs.trackersOff.remove(tracker.server) }
                                                 else { service.prefs.trackersOff.insert(tracker.server) }
                                             }))
            }
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(.studioMono(12.5))
                .foregroundStyle(StudioColors.ink)
                .focused($focused)
                .onSubmit(save)
                .onChange(of: focused) { _, now in if !now { save() } }
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.background))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(focused ? StudioColors.coral : StudioColors.line3, lineWidth: 1))
                .disabled(service.prefs.trackersOff.contains(tracker.server))
                .accessibilityLabel("\(tracker.name) query")
        }
        .onAppear { query = service.prefs.queries[tracker.server] ?? "" }
    }

    private var placeholder: String {
        tracker.kind == .glance || tracker.name == "Jira" ? "Optional JQL, e.g. project = ABC AND sprint in openSprints()"
            : "A view or filter (optional)"
    }

    private func save() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (service.prefs.queries[tracker.server] ?? "") != trimmed else { return }
        if trimmed.isEmpty { service.prefs.queries[tracker.server] = nil } else { service.prefs.queries[tracker.server] = trimmed }
    }
}
