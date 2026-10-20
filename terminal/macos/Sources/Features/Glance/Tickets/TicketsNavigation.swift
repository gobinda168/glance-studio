import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// What the Tickets page and side bar share (spec 2026-10-09-tickets-design.md, "Tickets page and side bar"): the
/// selected ticket, the tracker chip and filter text, and the page's keys.
@MainActor
final class TicketsNavigation: ObservableObject {
    static let shared = TicketsNavigation()

    @Published var selection: String?
    @Published var query = ""
    /// A tracker chip (its server), or nil for all.
    @Published var tracker: String?
    /// Bumped by ⌘F: the page focuses its filter field.
    @Published var focusFilter = 0
    /// The summary card was closed: it comes back with the next rank.
    @Published var summaryHidden = false

    private var service: TicketService { .shared }

    /// Today and Up next for the chip and the filter text (a key or words of a title), in Claude's order.
    func arranged() -> TicketRanking.Arranged {
        var tickets = service.book.tickets
        if let tracker { tickets = tickets.filter { $0.tracker == tracker } }
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !text.isEmpty {
            tickets = tickets.filter { $0.key.lowercased().contains(text) || $0.title.lowercased().contains(text) }
        }
        return TicketRanking.arrange(tickets, rank: service.book.rank)
    }

    /// The rows in the page's order, for ↑/↓.
    var visible: [Ticket] {
        let arranged = arranged()
        return (arranged.today + arranged.upNext).map(\.ticket)
    }

    func select(_ ticket: Ticket) { selection = ticket.id }

    /// Fetch, then Claude's order; the summary card comes back with it.
    func rerank() {
        summaryHidden = false
        service.rerank()
    }

    func open(_ ticket: Ticket) {
        selection = ticket.id
        TicketRouter.open(ticket)
    }

    private func step(_ offset: Int) {
        let ids = visible.map(\.id)
        guard !ids.isEmpty else { return }
        guard let current = selection, let index = ids.firstIndex(of: current) else {
            selection = offset > 0 ? ids.first : ids.last
            return
        }
        selection = ids[max(0, min(ids.count - 1, index + offset))]
    }

    /// ↑/↓ select, ↩ opens the ticket, R re-ranks, ⌘F filters. True when the key was taken.
    func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (event.keyCode, modifiers) {
        case (126, []):
            step(-1)
            return true
        case (125, []):
            step(1)
            return true
        case (36, []), (76, []):
            guard let id = selection, let ticket = service.book.ticket(id) else { return false }
            TicketRouter.open(ticket)
            return true
        case (3, [.command]):
            focusFilter += 1
            return true
        case (53, []):
            guard selection != nil else { return false }
            selection = nil
            return true
        default:
            break
        }
        if modifiers.isEmpty, event.charactersIgnoringModifiers?.lowercased() == "r" {
            rerank()
            return true
        }
        return false
    }
}

/// Words the page and the side bar share.
enum TicketText {
    /// "Due Fri" this week, "Due Oct 21" later, "Overdue" once past; `late` for the danger tone.
    static func due(_ date: Date, now: Date, calendar: Calendar = .current) -> (text: String, late: Bool) {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: today, to: day).day ?? 0
        if days < 0 { return ("Overdue", true) }
        if days == 0 { return ("Due today", false) }
        if days == 1 { return ("Due tomorrow", false) }
        if days < 7 { return ("Due " + date.formatted(.dateTime.weekday(.abbreviated)), false) }
        return ("Due " + date.formatted(.dateTime.month(.abbreviated).day()), false)
    }

    /// "9:12" today, "Tue 9:12" this week, else the date.
    static func asOf(_ date: Date?, now: Date) -> String {
        guard let date else { return "never" }
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if now.timeIntervalSince(date) < 6 * 86_400 {
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// The tone a status category reads in, always next to its words.
    static func tone(_ category: Ticket.StatusCategory) -> StatePill.Tone {
        switch category {
        case .todo, .unknown: .neutral
        case .inProgress: .amber
        case .review: .teal
        case .done: .ok
        }
    }

    /// Priority or severity, with a tone for the urgent ones (blockers red, high amber).
    static func urgency(_ ticket: Ticket) -> (text: String, tone: StatePill.Tone)? {
        let severity = TicketRanking.urgency(ticket.severity), priority = TicketRanking.urgency(ticket.priority)
        guard let text = severity <= priority ? ticket.severity ?? ticket.priority : ticket.priority else { return nil }
        switch min(severity, priority) {
        case 0: return (text, .danger)
        case 1: return (text, .amber)
        default: return (text, .neutral)
        }
    }
}
