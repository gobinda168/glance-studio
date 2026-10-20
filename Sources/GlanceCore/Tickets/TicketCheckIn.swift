import Foundation

/// The end-of-day check-in (spec "Morning card and check-in"): the tickets touched today — by a signal, a move, or a
/// session Claude matched — each with the status Glance suggests.
public enum TicketCheckIn {
  public static let maxSessions = 20

  public struct Row: Equatable, Identifiable, Sendable {
    public var ticket: Ticket
    public var suggestion: Suggestion?
    public var transition: Ticket.Transition?
    public var id: String { ticket.id }
  }

  public static func rows(book: TicketBook, matched: Set<String>, now: Date, calendar: Calendar) -> [Row] {
    var touched = matched
    for (id, date) in book.activity where calendar.isDate(date, inSameDayAs: now) { touched.insert(id) }
    for move in book.moves(on: now, calendar: calendar) { touched.insert(move.ticketID) }
    return book.tickets
      .filter { touched.contains($0.id) && $0.statusCategory != .done }
      .sorted { $0.key < $1.key }
      .map { ticket in
        let suggestion = book.suggestions.pending(for: ticket.id).first { $0.target != nil }
        return Row(ticket: ticket, suggestion: suggestion,
                   transition: suggestion?.target.flatMap { ticket.onlyTransition(to: $0) })
      }
  }

  public static func unmatched(_ sessions: [SessionNote], tickets: [Ticket]) -> [SessionNote] {
    sessions.filter { session in
      session.prompts.allSatisfy { TicketKeys.mentioned(in: $0, tickets: tickets, repository: nil).isEmpty }
    }
  }

  public static func matchPrompt(tickets: [Ticket], sessions: [SessionNote]) -> String {
    let ticketLines = tickets.map { "- \($0.key) · \($0.title)" }.joined(separator: "\n")
    let sessionLines = sessions.prefix(maxSessions).enumerated().map { index, session in
      let prompts = session.prompts.prefix(5).map { String($0.prefix(200)) }.joined(separator: " | ")
      return "\(index + 1). \(session.folder ?? "?") — \(prompts)"
    }.joined(separator: "\n")
    return """
      Match the user's Claude Code sessions from today to their tickets. Match only when a session clearly worked on \
      a ticket.

      Tickets:
      \(ticketLines)

      Sessions (folder — what the user asked):
      \(sessionLines)

      Answer with only JSON: {"matches":[{"key":"ABC-1","session":1}]} — or {"matches":[]} when none match.
      """
  }

  public static func matched(from reply: String, tickets: [Ticket]) -> Set<String> {
    guard let object = JournalRecap.jsonObject(in: reply), let matches = object["matches"] as? [[String: Any]] else {
      return []
    }
    var ids = Set<String>()
    for match in matches {
      guard let key = TicketPrompts.text(match["key"]),
            let ticket = tickets.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) else { continue }
      ids.insert(ticket.id)
    }
    return ids
  }
}
