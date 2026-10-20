import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The Meetings tab's page (spec 2026-10-09-meeting-notes-design.md): the start page, or one meeting (live while it's
/// recording).
struct MeetingsPage: View {
    @ObservedObject private var navigation = MeetingsNavigation.shared
    @ObservedObject private var library = MeetingNotesLibrary.shared
    @ObservedObject private var recorder = MeetingRecorder.shared

    var body: some View {
        switch navigation.page {
        case .start:
            MeetingsStartView()
        case .meeting(let id):
            if let live = recorder.record, live.id == id {
                MeetingView(record: live, current: true)
            } else if let record = library.records.first(where: { $0.id == id }) {
                MeetingView(record: record, current: false)
            } else {
                MeetingsStartView()
            }
        }
    }
}

/// The start page: Record, what happens to the audio, the model's state, today's calendar meetings with Join & Record,
/// and the user's open action items from the last two weeks.
struct MeetingsStartView: View {
    @ObservedObject private var library = MeetingNotesLibrary.shared
    @ObservedObject private var recorder = MeetingRecorder.shared
    @State private var window: NSWindow?

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                JournalPageHeader(title: "Meetings",
                                  subtitle: "Record a call. Glance transcribes it on this Mac and Claude writes the notes.")
                recordCard
                TodayMeetingsList(window: window)
                actionItems
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WindowAccessor { window = $0 })
        .onAppear { library.load() }
    }

    private var recordCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                if recorder.isRecording, let record = recorder.record {
                    StudioButton(title: "Open the Meeting Under Way", icon: .mic, style: .primary) {
                        MeetingsTabController.open(.meeting(record.id), from: window)
                    }
                } else {
                    StudioButton(title: "Record a Meeting", icon: .mic, style: .primary, enabled: !recorder.isBusy) {
                        MeetingsTabController.record(from: window)
                    }
                    if case .finishing(let what) = recorder.phase {
                        ProgressView().controlSize(.small)
                        Text(what).font(.studio(12)).foregroundStyle(StudioColors.muted)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                fact(.mic, "Your mic and the call's sound are kept apart, so the notes know what you said. Glance's own "
                     + "voice isn't recorded.")
                fact(.lock, "Transcribed on this Mac. Only the transcript goes to Claude Code, for the notes and your "
                     + "questions. The audio is deleted once the notes are done"
                     + (Prefs.meetingKeepRecordings ? ", unless Keep recordings is on (it is)." : "."))
                fact(.download, MeetingSpeechModels.isDownloaded
                     ? "The transcription model is on this Mac and loads only while a meeting is transcribed."
                     : "The first recording downloads the transcription model (about 600 MB); it records meanwhile.")
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(StudioColors.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(StudioColors.line, lineWidth: 1))
    }

    private func fact(_ icon: StudioIcons.Name, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            StudioIcon(icon, size: 15)
                .foregroundStyle(StudioColors.muted)
                .padding(.top, 1)
            Text(text)
                .font(.studio(12.5))
                .foregroundStyle(StudioColors.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The user's action items from meetings in the last 14 days.
    @ViewBuilder private var actionItems: some View {
        let since = Date().addingTimeInterval(-14 * 86_400)
        let items = library.records.filter { $0.start > since }.flatMap { record in
            (record.summary?.actionItems ?? []).filter(\.mine).map { (record, $0) }
        }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Caption("Your action items")
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        Button { MeetingsTabController.open(.meeting(item.0.id), from: window) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                ActionBox()
                                Text(item.1.task)
                                    .font(.studio(13))
                                    .foregroundStyle(StudioColors.ink)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text("\(item.0.title) · \(MeetingsFormat.day(item.0.start))")
                                    .font(.studio(11.5))
                                    .foregroundStyle(StudioColors.muted)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if index < items.count - 1 { Divider().overlay(StudioColors.line2) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StudioColors.card))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(StudioColors.line, lineWidth: 1))
            }
        }
    }
}

/// An action item's empty box: drawn, not a control (the notes are a record, not a to-do list).
struct ActionBox: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .strokeBorder(StudioColors.line3, lineWidth: 1.2)
            .frame(width: 12, height: 12)
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            .accessibilityHidden(true)
    }
}
