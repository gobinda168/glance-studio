import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// Today (spec "The Journal tab"): the note box, the live timeline, a quiet line for each source that collected
/// nothing, and Wrap up day. Once today has a recap, a line links to it.
struct JournalTodayView: View {
    @ObservedObject private var journal = JournalService.shared
    @State private var page: JournalDayPage?
    @State private var note = ""
    /// The note being edited in the box, if any.
    @State private var editing: JournalEvent?

    var body: some View {
        let today = journal.today
        let events = page?.events ?? []
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 22) {
                JournalPageHeader(title: "Today", subtitle: JournalFormat.long(today) + subtitle(events)) {
                    if journal.collecting { ProgressView().controlSize(.small) }
                }
                noteBox
                if let notes = page?.record?.sourceNotes, !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(notes.keys.sorted(), id: \.self) { source in
                            sourceNote(source, notes[source] ?? "")
                        }
                    }
                }
                if let summary = page?.summary, summary.status == .drafted || summary.status == .reviewed {
                    Button { JournalNavigation.shared.show(.day(today)) } label: {
                        Text("Today's recap is ready · Open")
                            .font(.studio(12.5, .semibold))
                            .foregroundStyle(StudioColors.coralInk)
                    }
                    .buttonStyle(.plain)
                }
                if events.isEmpty {
                    Text(journal.settings.enabled
                         ? "Nothing yet today. Glance looks every 15 minutes, and whenever you open this page."
                         : "Turn journaling on to start collecting your day.")
                        .font(.studio(13))
                        .foregroundStyle(StudioColors.muted)
                } else {
                    JournalTimeline(events: events, onEdit: { event in
                        editing = event
                        note = event.title
                    }, onDelete: { journal.deleteNote($0) })
                }
                wrapUp(today, hasEvents: !events.isEmpty)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { reload() }
        .onChange(of: journal.revision) { reload() }
    }

    private func subtitle(_ events: [JournalEvent]) -> String {
        events.isEmpty ? "" : " · \(events.count) event\(events.count == 1 ? "" : "s")"
    }

    private var noteBox: some View {
        HStack(alignment: .top, spacing: 10) {
            TextField("What happened that Glance can't see?", text: $note, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.studio(13))
                .foregroundStyle(StudioColors.ink)
                .lineLimit(1...5)
                .onSubmit(saveNote)
            if editing != nil {
                StudioButton(title: "Cancel", style: .quiet) {
                    editing = nil
                    note = ""
                }
            }
            StudioButton(title: editing == nil ? "Add Note" : "Save Note", style: .secondary,
                         enabled: !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: saveNote)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StudioColors.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(StudioColors.line, lineWidth: 1))
    }

    private func saveNote() {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let editing { journal.updateNote(editing, text: text) } else { journal.addNote(text) }
        editing = nil
        note = ""
    }

    private func sourceNote(_ source: String, _ reason: String) -> some View {
        HStack(spacing: 8) {
            Text("\(source): \(reason)")
                .font(.studio(12))
                .foregroundStyle(StudioColors.muted)
            if source == JournalSource.github.title && reason == "signed out" {
                StudioButton(title: "Sign In", style: .quiet, height: 24) { SidebarModeModel.shared.show(.pullRequests) }
            } else if source == JournalSource.calendar.title {
                StudioButton(title: "Allow Calendar Access", style: .quiet, height: 24) {
                    MeetingSettingsModel.shared.requestAccess()
                }
            }
        }
    }

    @ViewBuilder
    private func wrapUp(_ today: JournalDay, hasEvents: Bool) -> some View {
        if journal.settings.enabled {
            HStack(spacing: 12) {
                StudioButton(title: "Wrap up day", style: .primary, busy: journal.drafting.contains(today),
                             enabled: hasEvents && journal.claudeInstalled && !journal.drafting.contains(today)) {
                    journal.wrapUp(today)
                }
                if !journal.claudeInstalled {
                    Text("Recaps need Claude Code installed")
                        .font(.studio(12))
                        .foregroundStyle(StudioColors.muted)
                    StudioButton(title: "Get Claude Code", style: .quiet) {
                        NSWorkspace.shared.open(URL(string: "https://claude.com/claude-code")!)
                    }
                } else if journal.drafting.contains(today) {
                    Text("Claude is writing today's recap…")
                        .font(.studio(12))
                        .foregroundStyle(StudioColors.muted)
                }
            }
        }
    }

    private func reload() {
        journal.load(journal.today) { page = $0 }
    }
}
