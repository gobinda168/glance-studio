import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The Meetings side bar (spec 2026-10-09-meeting-notes-design.md):
/// - Record, or the meeting under way with its clock and Stop;
/// - the calendar meeting under way or up next, with Join & Record;
/// - a search field (title, notes, transcript);
/// - every meeting, newest first, under its day.
/// A row opens the window's Meetings tab on it.
struct MeetingsSidebarView: View {
    @ObservedObject private var library = MeetingNotesLibrary.shared
    @ObservedObject private var recorder = MeetingRecorder.shared
    @ObservedObject private var navigation = MeetingsNavigation.shared
    @State private var window: NSWindow?
    @State private var query = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let shown = library.records.filter { MeetingSearch.matches($0, query: query) }
        VStack(spacing: 0) {
            SidebarHeader(title: "Meetings")
            recordControl
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            UpNextMeeting(window: window)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            field
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 1) {
                    if shown.isEmpty {
                        Text(query.isEmpty ? "Recorded meetings show here." : "No meeting mentions “\(query)”.")
                            .font(.studio(12))
                            .foregroundStyle(StudioColors.muted)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    ForEach(Array(groups(shown).enumerated()), id: \.offset) { _, group in
                        Caption(group.day)
                            .padding(.horizontal, 10)
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                        ForEach(group.records) { record in
                            JournalSidebarRow(icon: nil, title: record.title, detail: detail(record),
                                              dot: dot(record), selected: navigation.page == .meeting(record.id)) {
                                MeetingsTabController.open(.meeting(record.id), from: window)
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WindowAccessor { window = $0 })
        .onAppear { library.load() }
    }

    @ViewBuilder private var recordControl: some View {
        if recorder.isRecording, let record = recorder.record {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 8) {
                    RecordingDot()
                    Button { MeetingsTabController.open(.meeting(record.id), from: window) } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Recording")
                                .font(.studio(12.5, .semibold))
                                .foregroundStyle(StudioColors.ink)
                            Text(MeetingsFormat.clock(record.duration(now: context.date)))
                                .font(.studioMono(11.5))
                                .foregroundStyle(StudioColors.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    StudioButton(title: "Stop", style: .secondary, height: 26) { recorder.stop() }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.card))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(StudioColors.line, lineWidth: 1))
        } else if case .finishing(let what) = recorder.phase {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(what)
                    .font(.studio(12))
                    .foregroundStyle(StudioColors.muted)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
        } else {
            StudioButton(title: "Record a Meeting", icon: .mic, style: .primary) {
                MeetingsTabController.record(from: window)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("Records your mic and the call's sound, transcribed on this Mac")
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            StudioIcon(.search, size: 14)
                .foregroundStyle(StudioColors.muted)
            TextField("Search meetings", text: $query)
                .textFieldStyle(.plain)
                .font(.studio(12))
                .foregroundStyle(StudioColors.ink)
                .focused($fieldFocused)
                .onExitCommand { query = "" }
                .accessibilityLabel("Search meetings")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(StudioColors.field))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(fieldFocused ? StudioColors.coral : StudioColors.line, lineWidth: 1))
    }

    private func groups(_ records: [MeetingRecord]) -> [(day: String, records: [MeetingRecord])] {
        var out: [(day: String, records: [MeetingRecord])] = []
        for record in records {
            let day = MeetingsFormat.day(record.start)
            if out.last?.day == day { out[out.count - 1].records.append(record) } else { out.append((day, [record])) }
        }
        return out
    }

    private func detail(_ record: MeetingRecord) -> String {
        let time = MeetingsFormat.time(record.start)
        switch record.status {
        case .recording: return "\(time) · recording"
        case .transcribing, .summarizing: return "\(time) · finishing"
        case .interrupted: return "\(time) · needs transcribing"
        case .ready:
            let length = MeetingsFormat.length(record.duration())
            if let overview = record.summary?.overview { return "\(time) · \(length) · \(overview)" }
            return "\(time) · \(length)"
        }
    }

    private func dot(_ record: MeetingRecord) -> Color {
        switch record.status {
        case .recording: GlanceColor.critical
        case .transcribing, .summarizing: StudioColors.amber
        case .interrupted: StudioColors.danger
        case .ready: record.summary == nil ? StudioColors.muted : StudioColors.ok
        }
    }
}

/// The red dot of a recording under way: a slow breath, still under Reduce Motion.
struct RecordingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(GlanceColor.critical)
            .frame(width: 9, height: 9)
            .opacity(dim ? 0.45 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityLabel("Recording")
    }
}
