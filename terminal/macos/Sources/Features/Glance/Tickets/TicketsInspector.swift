import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// True where the Tickets page shows the selected ticket in its side panel, so rows and cards don't also expand.
private struct TicketsInspectorKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var ticketsInspector: Bool {
        get { self[TicketsInspectorKey.self] }
        set { self[TicketsInspectorKey.self] = newValue }
    }
}

/// The selected ticket beside the list or board, on wide pages: who, what and when at a glance, why Claude put it
/// where it is, the Claude box, and the two ways on (open it, work on it). ✕ or Esc closes it.
struct TicketInspector: View {
    let ticket: Ticket
    let reason: String?
    let now: Date
    @ObservedObject private var navigation = TicketsNavigation.shared
    @ObservedObject private var service = TicketService.shared

    static let width: CGFloat = 360

    private var trackerName: String {
        service.allTrackers.first { $0.server == ticket.tracker }?.name ?? ticket.tracker
    }

    var body: some View {
        VStack(spacing: 0) {
            bar
            Rectangle().fill(StudioColors.line2).frame(height: 1)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 20) {
                    heading
                    if let reason { section("Why it's here") { prose(reason) } }
                    section("Details") { details }
                    section("Ask Claude") { TicketClaudeEdit(ticket: ticket, labelled: false) }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(StudioColors.line2).frame(height: 1)
            actions
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(StudioColors.bar)
        .id(ticket.id)
    }

    private var bar: some View {
        HStack(spacing: 8) {
            Text(ticket.key)
                .font(.studioMono(12, .medium))
                .foregroundStyle(StudioColors.muted)
                .textSelection(.enabled)
            Text("·").foregroundStyle(StudioColors.muted)
            Text(trackerName)
                .font(.studio(12))
                .foregroundStyle(StudioColors.muted)
            Spacer(minLength: 8)
            Button { navigation.selection = nil } label: {
                StudioIcon(.close, size: 12)
                    .foregroundStyle(StudioColors.muted)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
            .accessibilityLabel("Close details")
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ticket.title)
                .font(.studio(17, .semibold))
                .foregroundStyle(StudioColors.ink)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 8) {
                TicketStatusMenu(ticket: ticket)
                if let urgency = TicketText.urgency(ticket) {
                    StatePill(text: urgency.text, tone: urgency.tone, height: 20)
                }
                if let due = ticket.due {
                    let words = TicketText.due(due, now: now)
                    Text(words.text)
                        .font(.studioMono(11, words.late ? .medium : .regular))
                        .foregroundStyle(words.late ? StudioColors.danger : StudioColors.muted)
                        .help(due.formatted(date: .complete, time: .omitted))
                }
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            fact("Assignee", ticket.assignee ?? "Unassigned", muted: ticket.assignee == nil)
            if let sprint = ticket.sprint { fact("Sprint", sprint) }
            if let repository = ticket.repository { fact("Repository", repository, mono: true) }
            if let priority = ticket.priority { fact("Priority", priority) }
            if let updated = ticket.updated { fact("Updated", TicketText.asOf(updated, now: now)) }
            fact("List", ticket.group == .upNext ? "Up next · unassigned in your sprint"
                 : ticket.group == .query ? "Your saved query" : "Assigned to you")
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            StudioButton(title: "Open in \(trackerName)", icon: .globe, hint: "↩", style: .primary,
                         enabled: ticket.url != nil, height: 30) {
                TicketRouter.open(ticket)
            }
            if ticket.group == .upNext && ticket.statusCategory == .todo {
                StudioButton(title: "Assign + Start", style: .secondary, busy: service.moving.contains(ticket.id),
                             height: 30) { service.start(ticket) }
            } else {
                StudioButton(title: "Work on this", icon: .terminal, style: .secondary, height: 30) {
                    TicketRouter.workOn(ticket, near: NSApp.keyWindow)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption(title)
            content()
        }
    }

    private func prose(_ text: String) -> some View {
        Text(text)
            .font(.studio(13))
            .foregroundStyle(StudioColors.body)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func fact(_ label: String, _ value: String, mono: Bool = false, muted: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.studio(12))
                .foregroundStyle(StudioColors.muted)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(mono ? .studioMono(12) : .studio(12.5))
                .foregroundStyle(muted ? StudioColors.muted : StudioColors.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
