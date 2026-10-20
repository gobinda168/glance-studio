import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// Today's calendar meetings, under way or still to come (spec 2026-10-09-meeting-notes-design.md, "Today's meetings"),
/// read from the calendar the meeting nudges use.
@MainActor
enum TodayCalendar {
    static func meetings(now: Date = Date()) -> [MeetingEvent] {
        let source = MeetingNudger.shared.calendar
        guard source.access == .allowed else { return [] }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? now
        return TodayMeetings.list(source.events(from: start, to: end), now: now, calendar: calendar,
                                  calendarsOff: Set(Prefs.meetingCalendarsOff))
    }

    /// Opens the meeting (its app, else the browser) and starts its notes.
    static func joinAndRecord(_ event: MeetingEvent, from window: NSWindow?) {
        if let link = event.link { _ = MeetingNudger.open(link) }
        MeetingsTabController.record(title: event.title, eventID: event.id, from: window)
    }
}

/// The start page's Today list: each meeting with Join & Record and Record, Recording for the one under way, Notes for
/// one already recorded.
struct TodayMeetingsList: View {
    @ObservedObject private var library = MeetingNotesLibrary.shared
    @ObservedObject private var recorder = MeetingRecorder.shared
    let window: NSWindow?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let meetings = TodayCalendar.meetings(now: context.date)
            VStack(alignment: .leading, spacing: 8) {
                Caption("Today")
                if MeetingNudger.shared.calendar.access != .allowed {
                    Text("Allow calendar access in Settings → Meetings to see today's meetings here.")
                        .font(.studio(12.5))
                        .foregroundStyle(StudioColors.muted)
                } else if meetings.isEmpty {
                    Text("No more meetings today.")
                        .font(.studio(12.5))
                        .foregroundStyle(StudioColors.muted)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(meetings.enumerated()), id: \.element.id) { index, event in
                            row(event, now: context.date)
                            if index < meetings.count - 1 { Divider().overlay(StudioColors.line2) }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StudioColors.card))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(StudioColors.line, lineWidth: 1))
                }
            }
        }
    }

    private func row(_ event: MeetingEvent, now: Date) -> some View {
        let live = TodayMeetings.isLive(event, now: now)
        let recorded = library.records.first { $0.eventID == event.id }
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if live {
                        Text("Now")
                            .font(.studio(11, .semibold))
                            .foregroundStyle(StudioColors.onCoral)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(StudioColors.coral))
                    }
                    Text((event.start..<max(event.end, event.start)).formatted(.interval.hour().minute()))
                        .font(.studioMono(11.5))
                        .foregroundStyle(StudioColors.muted)
                }
                Text(event.title)
                    .font(.studio(13.5, .semibold))
                    .foregroundStyle(StudioColors.ink)
                    .lineLimit(1)
                Text("\(event.link?.provider.name ?? "No video link") · \(event.calendarTitle)")
                    .font(.studio(11.5))
                    .foregroundStyle(StudioColors.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            actions(event, recorded: recorded)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func actions(_ event: MeetingEvent, recorded: MeetingRecord?) -> some View {
        if let live = recorder.record, live.eventID == event.id {
            Button { MeetingsTabController.open(.meeting(live.id), from: window) } label: {
                HStack(spacing: 6) {
                    RecordingDot()
                    Text(recorder.isRecording ? "Recording" : "Finishing")
                        .font(.studio(12.5, .medium))
                        .foregroundStyle(StudioColors.ink)
                }
            }
            .buttonStyle(.plain)
        } else if let recorded {
            StudioButton(title: "Notes", style: .secondary, height: 28) {
                MeetingsTabController.open(.meeting(recorded.id), from: window)
            }
        } else {
            if event.link != nil {
                StudioButton(title: "Record", style: .quiet, enabled: !recorder.isBusy, height: 28) {
                    MeetingsTabController.record(title: event.title, eventID: event.id, from: window)
                }
                .help("Record without joining (you're already in it)")
                StudioButton(title: "Join & Record", style: .primary, enabled: !recorder.isBusy, height: 28) {
                    TodayCalendar.joinAndRecord(event, from: window)
                }
            } else {
                StudioButton(title: "Record", style: .primary, enabled: !recorder.isBusy, height: 28) {
                    MeetingsTabController.record(title: event.title, eventID: event.id, from: window)
                }
            }
        }
    }
}

/// The side bar's Up next: the meeting under way or the next one today, with Join & Record.
struct UpNextMeeting: View {
    @ObservedObject private var recorder = MeetingRecorder.shared
    let window: NSWindow?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if !recorder.isBusy, let event = TodayCalendar.meetings(now: context.date).first {
                let live = TodayMeetings.isLive(event, now: context.date)
                VStack(alignment: .leading, spacing: 6) {
                    Caption(live ? "Now" : "Up next")
                    Text(event.title)
                        .font(.studio(12.5, .semibold))
                        .foregroundStyle(StudioColors.ink)
                        .lineLimit(1)
                    Text("\(MeetingsFormat.time(event.start)) · \(event.link?.provider.name ?? "No video link")")
                        .font(.studio(11.5))
                        .foregroundStyle(StudioColors.muted)
                        .lineLimit(1)
                    StudioButton(title: event.link == nil ? "Record" : "Join & Record", icon: .mic, style: .secondary,
                                 height: 26) {
                        TodayCalendar.joinAndRecord(event, from: window)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.card))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(StudioColors.line, lineWidth: 1))
            }
        }
    }
}
