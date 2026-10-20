import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The Journal side bar (spec "The Journal tab"):
/// - a filter field;
/// - the fixed Today and Insights rows;
/// - every past day, newest first, with its date, headline and status dot.
/// A row opens the window's Journal tab on it.
struct JournalSidebarView: View {
    @ObservedObject private var journal = JournalService.shared
    @ObservedObject private var navigation = JournalNavigation.shared
    @State private var window: NSWindow?
    @State private var text = ""
    /// The days the filter matched; nil while it's blank.
    @State private var matches: Set<JournalDay>?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let today = journal.today
        let days = journal.summaries.filter { $0.day != today && (matches?.contains($0.day) ?? true) }
        VStack(spacing: 0) {
            SidebarHeader(title: "Journal") {
                if journal.collecting {
                    ProgressView().controlSize(.mini).padding(.trailing, 8)
                }
            }
            field
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 1) {
                    JournalSidebarRow(icon: .clock, title: "Today", detail: todayDetail(today), dot: StudioColors.coral,
                                      selected: navigation.page == .today) { open(.today) }
                    JournalSidebarRow(icon: .chart, title: "Insights", detail: "Time, output, skills, journey",
                                      dot: nil, selected: navigation.page == .insights) { open(.insights) }
                    Caption("Days")
                        .padding(.horizontal, 10)
                        .padding(.top, 14)
                        .padding(.bottom, 4)
                    if days.isEmpty {
                        Text(matches == nil ? "Past days show here." : "No day mentions “\(text)”.")
                            .font(.studio(12))
                            .foregroundStyle(StudioColors.muted)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    ForEach(days) { summary in
                        JournalSidebarRow(icon: nil, title: JournalFormat.short(summary.day), detail: detail(summary),
                                          dot: dot(summary.status), selected: navigation.page == .day(summary.day)) {
                            open(.day(summary.day))
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WindowAccessor { window = $0 })
        .onChange(of: text) { refilter() }
        .onChange(of: journal.revision) { refilter() }
    }

    private var field: some View {
        HStack(spacing: 8) {
            StudioIcon(.search, size: 14)
                .foregroundStyle(StudioColors.muted)
            TextField("Filter days", text: $text)
                .textFieldStyle(.plain)
                .font(.studio(12))
                .foregroundStyle(StudioColors.ink)
                .focused($fieldFocused)
                .onExitCommand { text = "" }
                .accessibilityLabel("Filter days")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(StudioColors.field))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(fieldFocused ? StudioColors.coral : StudioColors.line, lineWidth: 1))
    }

    private func refilter() {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return matches = nil }
        journal.search(query) { days in
            guard text.trimmingCharacters(in: .whitespaces) == query else { return }
            matches = Set(days)
        }
    }

    private func open(_ page: JournalNavigation.Page) {
        JournalTabController.open(page, from: window)
    }

    private func todayDetail(_ today: JournalDay) -> String {
        guard let summary = journal.summaries.first(where: { $0.day == today }) else {
            return journal.settings.enabled ? "Live · nothing yet" : "Journaling is off"
        }
        if !summary.headline.isEmpty { return summary.headline }
        return "Live · \(summary.eventCount) event\(summary.eventCount == 1 ? "" : "s")"
    }

    private func detail(_ summary: JournalDaySummary) -> String {
        switch summary.status {
        case .failed: "Recap failed"
        case .open: "Not recapped · \(summary.eventCount) event\(summary.eventCount == 1 ? "" : "s")"
        case .drafted, .reviewed: summary.headline
        }
    }

    private func dot(_ status: JournalDayRecord.Status) -> Color {
        switch status {
        case .open: StudioColors.muted
        case .drafted: StudioColors.amber
        case .reviewed: StudioColors.ok
        case .failed: StudioColors.danger
        }
    }
}

/// A side bar row: an icon or a status dot, a title, and a muted line under it.
struct JournalSidebarRow: View {
    let icon: StudioIcons.Name?
    let title: String
    let detail: String
    let dot: Color?
    let selected: Bool
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                Group {
                    if let icon {
                        StudioIcon(icon, size: 16)
                            .foregroundStyle(selected || hovering ? StudioColors.ink : StudioColors.muted)
                    } else if let dot {
                        Circle().fill(dot).frame(width: 7, height: 7).padding(.top, 5)
                    }
                }
                .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.studio(13, selected ? .semibold : .medium))
                        .foregroundStyle(StudioColors.ink)
                    Text(detail)
                        .font(.studio(11.5))
                        .foregroundStyle(StudioColors.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background { SettingsRowPlate(selected: selected, hovering: hovering) }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .accessibilityLabel("\(title), \(detail)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
