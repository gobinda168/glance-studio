import GlanceCore
import GlanceKit
import SwiftUI

/// A day's events along a hairline spine (Home's session-log look, design-system/glance/pages/home.md), grouped by
/// project with the most recent work first, then meetings and notes. Notes can be edited or deleted from their menu.
struct JournalTimeline: View {
    let events: [JournalEvent]
    var onEdit: ((JournalEvent) -> Void)?
    var onDelete: ((JournalEvent) -> Void)?

    private struct Group: Identifiable {
        let id: String
        let title: String
        let events: [JournalEvent]
    }

    private var groups: [Group] {
        let worked = Dictionary(grouping: events.filter { $0.source != .meeting && $0.source != .note }) {
            $0.project ?? ""
        }
        let projects = worked.map { project, events in
            Group(id: project, title: project.isEmpty ? "Elsewhere" : FolderLabel.name(forPath: project),
                  events: events.sorted { $0.start > $1.start })
        }.sorted { ($0.events.first?.start ?? .distantPast) > ($1.events.first?.start ?? .distantPast) }
        var groups = projects
        let meetings = events.filter { $0.source == .meeting }.sorted { $0.start > $1.start }
        if !meetings.isEmpty { groups.append(Group(id: "meetings", title: "Meetings", events: meetings)) }
        let notes = events.filter { $0.source == .note }.sorted { $0.start > $1.start }
        if !notes.isEmpty { groups.append(Group(id: "notes", title: "Notes", events: notes)) }
        return groups
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 0) {
                    Caption(group.title)
                        .padding(.bottom, 8)
                    ForEach(group.events) { event in
                        JournalEventRow(event: event)
                            .contextMenu {
                                if event.source == .note {
                                    Button("Edit Note") { onEdit?(event) }
                                    Button("Delete Note", role: .destructive) { onDelete?(event) }
                                }
                            }
                    }
                }
            }
        }
    }
}

/// One event: its time on the spine, its glyph, its title and a muted line of facts.
private struct JournalEventRow: View {
    let event: JournalEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(JournalFormat.time(event.start))
                .font(.studioMono(11))
                .foregroundStyle(StudioColors.muted)
                .frame(width: 64, alignment: .trailing)
                .padding(.top, 2)
            StudioIcon(glyph, size: 13)
                .foregroundStyle(event.source == .note ? StudioColors.coralInk : StudioColors.body)
                .padding(3)
                .background(Circle().fill(StudioColors.background))
                .frame(width: 20)
                .frame(maxHeight: .infinity, alignment: .top)
                .background { Rectangle().fill(StudioColors.line).frame(width: 1) }
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.studio(13, .medium))
                    .foregroundStyle(StudioColors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !facts.isEmpty {
                    Text(facts)
                        .font(.studio(11.5))
                        .foregroundStyle(StudioColors.muted)
                }
            }
            .padding(.bottom, 12)
            Spacer(minLength: 0)
        }
        // The row takes its content's height, so the spine runs unbroken from row to row.
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private var glyph: StudioIcons.Name {
        switch event.source {
        case .claude: .agents
        case .git: .commit
        case .pr: event.detail.action == "merged" ? .merge : .pullRequest
        case .review: .reply
        case .meeting: .clock
        case .note: .pencil
        }
    }

    private var facts: String {
        let detail = event.detail
        switch event.source {
        case .claude:
            var parts = ["\(detail.activeMinutes ?? 0) active min"]
            if let turns = detail.turns { parts.append("\(turns) prompt\(turns == 1 ? "" : "s")") }
            if let files = detail.files, !files.isEmpty { parts.append("\(files.count) file\(files.count == 1 ? "" : "s")") }
            if let branch = detail.branch { parts.append(branch) }
            return parts.joined(separator: " · ")
        case .git:
            guard let files = detail.filesChanged else { return detail.hash.map { String($0.prefix(7)) } ?? "" }
            return "+\(detail.insertions ?? 0) −\(detail.deletions ?? 0) · \(files) file\(files == 1 ? "" : "s")"
        case .pr:
            return "\(detail.action == "merged" ? "Merged" : "Opened") #\(detail.number ?? 0)"
                + (detail.repository.map { " · \($0)" } ?? "")
        case .review:
            let comments = detail.comments ?? 0
            return (detail.reviewState ?? "reviewed").replacingOccurrences(of: "_", with: " ").capitalized
                + " · \(comments) comment\(comments == 1 ? "" : "s")" + (detail.repository.map { " · \($0)" } ?? "")
        case .meeting:
            let end = event.end.map { "–" + JournalFormat.time($0) } ?? ""
            return JournalFormat.time(event.start) + end + (detail.calendar.map { " · \($0)" } ?? "")
        case .note:
            return ""
        }
    }
}

/// A page's title and the muted line under it.
struct JournalPageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.studio(22, .bold))
                    .tracking(-0.22)
                    .foregroundStyle(StudioColors.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.studio(12.5))
                    .foregroundStyle(StudioColors.muted)
            }
            Spacer(minLength: 0)
            trailing
        }
    }
}

extension JournalPageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}
