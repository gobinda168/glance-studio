import GlanceCore
import GlanceKit
import SwiftUI

/// A day (spec "A past day"):
/// - its headline, recap and entries;
/// - Mark reviewed, Redraft (asking first on a reviewed day) and Delete this day;
/// - "N new since the recap · Update";
/// - its raw timeline, collapsed.
/// An open day offers Draft recap; a failed one shows why, with Retry.
struct JournalDayView: View {
    let day: JournalDay
    @ObservedObject private var journal = JournalService.shared
    @State private var page: JournalDayPage?
    @State private var confirmRedraft = false
    @State private var confirmDelete = false
    @State private var showEvents = false

    var body: some View {
        let record = page?.record
        let status = record?.status ?? .open
        let drafting = journal.drafting.contains(day)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                JournalPageHeader(title: JournalFormat.long(day), subtitle: statusLine(status)) {
                    HStack(spacing: 8) {
                        if status == .drafted {
                            StudioButton(title: "Mark reviewed", style: .primary) { journal.markReviewed(day) }
                        }
                        StudioButton(title: status == .open ? "Draft recap" : "Redraft", busy: drafting,
                                     enabled: !drafting && journal.claudeInstalled && !(page?.events.isEmpty ?? true)) {
                            redraft(status)
                        }
                    }
                }
                if let new = page?.summary?.newSinceRecap, new > 0, status != .open {
                    Button { redraft(status) } label: {
                        Text("\(new) new since the recap · Update")
                            .font(.studio(12.5, .semibold))
                            .foregroundStyle(StudioColors.coralInk)
                    }
                    .buttonStyle(.plain)
                }
                if status == .failed, let error = record?.error {
                    Text(error)
                        .font(.studio(12.5))
                        .foregroundStyle(StudioColors.danger)
                }
                if drafting {
                    Text("Claude is writing this day's recap…")
                        .font(.studio(12.5))
                        .foregroundStyle(StudioColors.muted)
                }
                if let record, !record.headline.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(record.headline)
                            .font(.studio(18, .semibold))
                            .foregroundStyle(StudioColors.ink)
                        Text(markdown(record.recap))
                            .font(.studio(13.5))
                            .foregroundStyle(StudioColors.body)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(page?.entries ?? []) { entry in
                        JournalEntryCard(entry: entry)
                    }
                    StudioButton(title: "Add entry", icon: .plus, style: .quiet) { journal.addEntry(on: day) }
                }
                if let events = page?.events, !events.isEmpty {
                    DisclosureGroup(isExpanded: $showEvents) {
                        JournalTimeline(events: events, onDelete: { journal.deleteNote($0) })
                            .padding(.top, 10)
                    } label: {
                        Text("What happened · \(events.count) event\(events.count == 1 ? "" : "s")")
                            .font(.studio(12.5, .semibold))
                            .foregroundStyle(StudioColors.muted)
                    }
                }
                StudioButton(title: "Delete this day", icon: .trash, style: .quiet) { confirmDelete = true }
                    .padding(.top, 12)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Redraft this reviewed day?", isPresented: $confirmRedraft) {
            Button("Redraft") { journal.redraft(day) }
        } message: {
            Text("Your edited entries are kept.")
        }
        .confirmationDialog("Delete this day?", isPresented: $confirmDelete) {
            Button("Delete This Day", role: .destructive) {
                journal.deleteDay(day)
                JournalNavigation.shared.show(.today)
            }
        } message: {
            Text("Its events, recap and entries are removed from this Mac.")
        }
        .onAppear { reload() }
        .onChange(of: journal.revision) { reload() }
        .onChange(of: day) { reload() }
    }

    private func statusLine(_ status: JournalDayRecord.Status) -> String {
        switch status {
        case .open: "Not recapped yet"
        case .drafted: "Drafted by Claude · review and edit it"
        case .reviewed: "Reviewed"
        case .failed: "The recap failed"
        }
    }

    private func redraft(_ status: JournalDayRecord.Status) {
        if status == .reviewed { confirmRedraft = true } else { journal.redraft(day) }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private func reload() {
        journal.load(day) { page = $0 }
    }
}
