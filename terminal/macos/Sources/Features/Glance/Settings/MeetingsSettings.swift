import GlanceCore
import GlanceKit
import SwiftUI

/// Meetings (spec 2026-10-08-meeting-nudges-design.md, "Settings → Meetings"): the nudge when each meeting starts,
/// calendar access, the voice or sound, and which calendars count.
struct MeetingsSettings: View {
    @ObservedObject private var model = MeetingSettingsModel.shared
    @ObservedObject private var features = StudioFeatures.shared

    var body: some View {
        let live = model.nudges && model.access == .allowed
        SettingsGroup(title: "Nudges") {
            SettingsRow(id: "meetings.enabled", name: "Meeting nudges",
                        detail: "When a meeting starts, a nudge drops in at the top of the screen, over any app, "
                            + "with Join and Decline.") {
                SettingsSwitch(label: "Meeting nudges",
                               isOn: Binding(get: { model.nudges }, set: { model.setNudges($0) }))
            }
            SettingsRow(id: "meetings.access", name: "Calendar access", detail: accessDetail,
                        light: model.access == .allowed) {
                switch model.access {
                case .allowed: EmptyView()
                case .notAsked: StudioButton(title: "Allow Calendar Access") { model.requestAccess() }
                case .denied: StudioButton(title: "Open Privacy Settings") { model.openPrivacySettings() }
                }
            }
            SettingsRow(id: "meetings.speak", name: "Say it out loud",
                        detail: "\"Hey \(NSFullUserName().split(separator: " ").first.map(String.init) ?? "there"), "
                            + "Sprint planning is starting now.\" In your voice from Settings → Voice.",
                        dimmed: !live) {
                SettingsSwitch(label: "Say it out loud", isOn: Binding(get: { model.speak }, set: { model.setSpeak($0) }))
            }
            SettingsRow(id: "meetings.sound", name: "Play a sound", detail: "A soft chime when a meeting's nudge first "
                            + "appears, while Say it out loud is off.", dimmed: !live || model.speak) {
                SettingsSwitch(label: "Play a sound", isOn: Binding(get: { model.sound }, set: { model.setSound($0) }))
            }
            SettingsRow(id: "meetings.floating", name: "Join in Studio's browser",
                        detail: "Join opens the call in a Browser tab. Press PiP in the tab's top bar to float it "
                            + "above your other windows, so you can work while you listen; attach it back from the "
                            + "floating window.") {
                SettingsSwitch(label: "Join in Studio's browser",
                               isOn: Binding(get: { model.joinInBrowser }, set: { model.setJoinInBrowser($0) }))
            }
            SettingsRow(id: "meetings.test", name: "Show a test nudge",
                        detail: "A made-up meeting starting now, to see and hear the nudge. Its buttons only close it.") {
                StudioButton(title: "Show Test Nudge") { model.showTestNudge() }
            }
        }
        SettingsGroup(title: "Calendars") {
            SettingsRow(id: "meetings.calendars", name: "Calendars", detail: calendarsDetail, dimmed: !live,
                        stacked: true) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(accounts, id: \.self) { account in
                        VStack(alignment: .leading, spacing: 6) {
                            Caption(account)
                            ForEach(model.calendars.filter { $0.account == account }) { calendar in
                                Toggle(isOn: Binding(get: { !model.calendarsOff.contains(calendar.id) },
                                                     set: { model.setCalendar(calendar.id, on: $0) })) {
                                    HStack(spacing: 7) {
                                        Circle().fill(Color(cgColor: calendar.color)).frame(width: 8, height: 8)
                                        Text(calendar.title)
                                            .font(.studio(13))
                                            .foregroundStyle(StudioColors.ink)
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                }
            }
            SettingsRow(id: "meetings.google", name: "Google Calendar", detail: googleDetail,
                        light: google.email != nil) {
                switch google.state {
                case .notSetUp:
                    EmptyView()
                case .signedOut:
                    StudioButton(title: "Sign in with Google") { Task { _ = try? await google.signIn() } }
                case .signingIn:
                    StudioButton(title: "Cancel") { google.cancelSignIn() }
                case .signedIn:
                    StudioButton(title: "Sign Out") { google.signOut() }
                }
            }
        }
        .onAppear { model.reload() }
        if features.isOn(.meetingNotes) { MeetingNotesSettings() }
    }

    private var google: GoogleAccount { .shared }

    private var googleDetail: String {
        switch google.state {
        case .notSetUp: "Google sign-in isn't set up in this build."
        case .signedOut: "Sign in so Decline on a nudge declines the invite in Google Calendar."
        case .signingIn: "Waiting for your browser…"
        case .signedIn(let email):
            "Signed in as \(email). Decline on a nudge declines the invite and tells the organizer."
        }
    }

    private var accessDetail: String {
        switch model.access {
        case .allowed: "Allowed. Glance reads the calendars in the Calendar app, including your Google Workspace account."
        case .notAsked: "Not asked yet. Glance reads the calendars in the Calendar app; nothing leaves this Mac."
        case .denied: "Not allowed. Turn on Glance Studio in Privacy & Security → Calendars."
        }
    }

    private var calendarsDetail: String {
        model.calendars.isEmpty
            ? "Your calendars show here once Glance can read them. Add accounts in the Calendar app."
            : "Meetings from the ticked calendars nudge you. All-day events and ones you declined never do."
    }

    private var accounts: [String] {
        model.calendars.map(\.account).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }
}
