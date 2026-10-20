import GlanceCore
import GlanceKit
import SwiftUI

/// The first thing Journal shows (spec "The on/off switch and disclaimer"): what it reads, where it keeps it, what
/// leaves the Mac, a switch per source, then Start journaling. Plain words, no fine print.
struct JournalSetupView: View {
    @ObservedObject private var journal = JournalService.shared
    @ObservedObject private var meetings = MeetingSettingsModel.shared

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                StudioIcon(.journal, size: 26)
                    .foregroundStyle(StudioColors.coral)
                    .padding(.bottom, 14)
                Text("Your dev journey, written down each day")
                    .font(.studio(24, .bold))
                    .tracking(-0.24)
                    .foregroundStyle(StudioColors.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("Glance keeps track of what you work on. At the end of the day Claude drafts a short recap of "
                    + "what you got done, with the story behind each piece. Every day is kept, and Insights shows "
                    + "your work grow over months.")
                    .font(.studio(13.5))
                    .foregroundStyle(StudioColors.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                SettingsGroup(title: "What Journal reads") {
                    ForEach(JournalSource.allCases, id: \.self) { source in
                        SettingsRow(id: "setup.\(source.rawValue)", name: source.title, detail: source.detail) {
                            SettingsSwitch(label: source.title, isOn: Binding(
                                get: { !journal.settings.sourcesOff.contains(source) },
                                set: { journal.setSource(source, on: $0) }))
                        }
                    }
                }
                SettingsGroup(title: "Before you start") {
                    Disclosure(title: "Where it's kept",
                               text: "Only on this Mac, in ~/Library/Application Support/Glance/journal.sqlite. "
                                   + "Journal doesn't sync or upload anything.")
                    Disclosure(title: "What leaves this Mac",
                               text: "Once a day, and whenever you ask for a recap, a summary of that day is sent to "
                                   + "Claude through your own Claude Code sign-in, like any claude command you run. "
                                   + "Secrets such as tokens and keys are removed first. Whole conversations, code "
                                   + "and diffs are never sent.")
                    Disclosure(title: "What may be in it",
                               text: "Work details like project names, customers or file paths can appear in your "
                                   + "recaps. Treat them as private work notes.")
                    Disclosure(title: "Your control",
                               text: "Turn Journal or any source off, export everything, or delete a day or all of "
                                   + "it at any time, in Settings → Journal.")
                }
                HStack(spacing: 12) {
                    StudioButton(title: "Start journaling", style: .primary, height: 34) { start() }
                    if !journal.claudeInstalled {
                        Text("Recaps need Claude Code installed")
                            .font(.studio(12))
                            .foregroundStyle(StudioColors.muted)
                    }
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func start() {
        if !journal.settings.sourcesOff.contains(.calendar) && meetings.access == .notAsked {
            meetings.requestAccess()
        }
        journal.setEnabled(true)
        JournalNavigation.shared.show(.today)
    }
}

/// One of the disclaimer's points: a title and its words, always visible.
private struct Disclosure: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.studio(13, .semibold))
                .foregroundStyle(StudioColors.ink)
            Text(text)
                .font(.studio(12.5))
                .foregroundStyle(StudioColors.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(StudioColors.line2).frame(height: 1) }
    }
}
