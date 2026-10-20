import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// How the Tickets page lays its tickets out; the choice is remembered.
enum TicketsLayout: String {
    case list, board
}

/// The List / Board switch.
struct TicketsLayoutPicker: View {
    @AppStorage("ticketsLayout") private var layout: TicketsLayout = .list

    var body: some View {
        SegmentedTabs(items: [SegmentItem(value: TicketsLayout.list, title: "List", count: nil),
                              SegmentItem(value: TicketsLayout.board, title: "Board", count: nil)],
                      selection: $layout)
    }
}

/// The board: a column per status, taken from the tickets' own status names (plus any status a ticket can move to, so
/// there is somewhere to drop it), in workflow order. Dragging a card onto a column moves the ticket there through the
/// same path as the status menu; a status it can't move to refuses the drop. Clicking a card previews it in place.
struct TicketsBoard: View {
    let tickets: [Ticket]
    let now: Date
    @ObservedObject private var service = TicketService.shared

    struct Column: Identifiable {
        let name: String
        let category: Ticket.StatusCategory
        var tickets: [Ticket]
        var id: String { name.lowercased() }
    }

    var columns: [Column] {
        var byName: [String: Column] = [:]
        func column(_ name: String, _ category: Ticket.StatusCategory) {
            if byName[name.lowercased()] == nil { byName[name.lowercased()] = Column(name: name, category: category, tickets: []) }
        }
        for ticket in tickets {
            column(ticket.status, ticket.statusCategory)
            for transition in ticket.transitions { column(transition.name, transition.category) }
        }
        for ticket in tickets { byName[ticket.status.lowercased()]?.tickets.append(ticket) }
        return byName.values.sorted {
            ($0.category.step ?? 9, $0.name) < ($1.category.step ?? 9, $1.name)
        }
    }

    @State private var width: CGFloat = 0

    private static let spacing: CGFloat = 12
    private static let minColumn: CGFloat = 232
    private static let maxColumn: CGFloat = 340

    /// Columns share the page's width between a minimum and a maximum; past that the board scrolls sideways.
    private func columnWidth(_ count: Int) -> CGFloat {
        guard count > 0, width > 0 else { return Self.minColumn }
        let share = (width - Self.spacing * CGFloat(count - 1)) / CGFloat(count)
        return min(Self.maxColumn, max(Self.minColumn, share.rounded(.down)))
    }

    var body: some View {
        let all = columns
        let each = columnWidth(all.count)
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Self.spacing) {
                ForEach(all) { column in
                    BoardColumn(column: column, now: now, width: each, move: drop)
                }
            }
            .padding(.vertical, 2)
            .fixedSize(horizontal: false, vertical: true)
        }
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity)
        .background(GeometryReader { proxy in
            Color.clear.onAppear { width = proxy.size.width }
                .onChange(of: proxy.size.width) { _, new in width = new }
        })
    }

    /// Move the dragged tickets into the column; true when one moved.
    private func drop(_ ids: [String], into column: Column) -> Bool {
        var moved = false
        for id in ids {
            guard let ticket = service.book.ticket(id), ticket.status.lowercased() != column.id else { continue }
            guard let transition = ticket.transitions.first(where: { $0.name.lowercased() == column.id }) else {
                NSSound.beep()
                continue
            }
            service.move(ticket, to: transition, reason: "By you", auto: false)
            moved = true
        }
        return moved
    }
}

private struct BoardColumn: View {
    let column: TicketsBoard.Column
    let now: Date
    let width: CGFloat
    let move: ([String], TicketsBoard.Column) -> Bool
    @State private var targeted = false

    /// The status light, as on the list's spine.
    private var light: Color {
        switch column.category {
        case .todo, .unknown: StudioColors.background
        case .inProgress: StudioColors.amber
        case .review: StudioColors.tealInk
        case .done: StudioColors.ok
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(light)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().strokeBorder(StudioColors.line3,
                                                   lineWidth: column.category == .todo ? 1 : 0))
                Caption(column.name)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(column.tickets.count)")
                    .font(.studioMono(11, .medium))
                    .foregroundStyle(StudioColors.muted)
                    .monospacedDigit()
            }
            .frame(height: 26)
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
            if column.tickets.isEmpty {
                Text(targeted ? "Drop to move here" : "No tickets")
                    .font(.studio(12))
                    .foregroundStyle(StudioColors.muted)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(StudioColors.line2, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
            ForEach(column.tickets) { ticket in
                BoardCard(ticket: ticket, now: now)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(targeted ? StudioColors.selection : StudioColors.chip.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(targeted ? StudioColors.coral : StudioColors.line2, lineWidth: 1))
        .animation(.easeOut(duration: 0.14), value: targeted)
        .dropDestination(for: String.self) { ids, _ in move(ids, column) } isTargeted: { targeted = $0 }
    }
}

private struct BoardCard: View {
    let ticket: Ticket
    let now: Date
    @ObservedObject private var navigation = TicketsNavigation.shared
    @ObservedObject private var service = TicketService.shared

    @State private var hovering = false
    private var selected: Bool { navigation.selection == ticket.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ticket.key)
                .font(.studioMono(11, .medium))
                .foregroundStyle(StudioColors.muted)
            Text(ticket.title)
                .font(.studio(12.5, .semibold))
                .foregroundStyle(StudioColors.ink)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if let urgency = TicketText.urgency(ticket) {
                    StatePill(text: urgency.text, tone: urgency.tone, height: 18)
                }
                if let due = ticket.due {
                    let words = TicketText.due(due, now: now)
                    Text(words.text)
                        .font(.studioMono(10.5, words.late ? .medium : .regular))
                        .foregroundStyle(words.late ? StudioColors.danger : StudioColors.muted)
                }
                if service.moving.contains(ticket.id) { ProgressView().controlSize(.mini) }
            }
            TicketPreview(ticket: ticket, reason: nil, now: now, indent: 0)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StudioColors.card)
            .shadow(color: .black.opacity(hovering || selected ? 0.14 : 0.06), radius: hovering ? 4 : 2, y: 1))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(selected ? StudioColors.coral : hovering ? StudioColors.line3 : StudioColors.line2,
                          lineWidth: selected ? 1.5 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .animation(.easeOut(duration: 0.18), value: selected)
        .onTapGesture { navigation.select(ticket) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { navigation.open(ticket) })
        .draggable(ticket.id)
        .contextMenu { TicketMenu(ticket: ticket) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(ticket.key), \(ticket.title), \(ticket.status)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityAction { navigation.open(ticket) }
    }
}

/// "Change this with Claude": the user says what they want in their own words, Claude proposes, and nothing is
/// written to the tracker until they confirm. Only a status move can be carried out so far.
struct TicketClaudeEdit: View {
    let ticket: Ticket
    var labelled = true
    @ObservedObject private var service = TicketService.shared
    @State private var text = ""
    @State private var asking: ClaudeOneShot.Run?
    @State private var proposal: TicketPrompts.Edit?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if labelled { Caption("Ask Claude") }
            HStack(spacing: 6) {
                StudioField(placeholder: "Describe a change, e.g. “move to review”", text: $text, height: 28, font: .studio(12),
                            submit: ask)
                if asking != nil {
                    ProgressView().controlSize(.small).frame(height: 28)
                } else {
                    StudioButton(title: "Ask", style: .secondary, enabled: !trimmed.isEmpty, height: 28, action: ask)
                }
            }
            if let failure {
                Text(failure).font(.studio(11.5)).foregroundStyle(StudioColors.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let proposal {
                VStack(alignment: .leading, spacing: 6) {
                    Text(proposal.transition.map { "Claude proposes: move to \($0.name)" } ?? "Claude can't do that yet")
                        .font(.studio(12, .semibold)).foregroundStyle(StudioColors.ink)
                    if !proposal.note.isEmpty {
                        Text(proposal.note).font(.studio(12)).foregroundStyle(StudioColors.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 6) {
                        if let transition = proposal.transition {
                            StudioButton(title: "Confirm", style: .primary, busy: service.moving.contains(ticket.id),
                                         height: 24) {
                                service.move(ticket, to: transition, reason: "By you, with Claude", auto: false)
                                self.proposal = nil
                                text = ""
                            }
                        }
                        StudioButton(title: "Dismiss", style: .quiet, height: 24) { self.proposal = nil }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.selection))
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.16), value: proposal)
        .onDisappear { asking?.cancel() }
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func ask() {
        guard !trimmed.isEmpty, asking == nil else { return }
        failure = nil
        proposal = nil
        asking = service.proposeEdit(ticket, request: trimmed) { result in
            asking = nil
            switch result {
            case .success(let edit): proposal = edit
            case .failure(let error): failure = error.message
            }
        }
    }
}
