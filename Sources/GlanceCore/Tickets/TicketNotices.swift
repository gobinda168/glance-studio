import Foundation

extension Ticket {
  /// The one transition into `category`, or nil when there's none or more than one (the user chooses).
  public func onlyTransition(to category: StatusCategory) -> Transition? {
    let matching = transitions.filter { $0.category == category }
    return matching.count == 1 ? matching[0] : nil
  }
}

/// Tickets' notices in the Notifications inbox (spec "Signals, suggestions, policy" and "Errors"), and the ids of the
/// buttons they carry. Every notice about a ticket shares its thread, so the inbox folds them into one row.
public enum TicketNotices {
  public enum Action: Equatable, Sendable {
    case move(String)
    case snooze(String)
    case mute
    case undo(String)
    case retry(String)
    case choose

    public var id: String {
      switch self {
      case .move(let transition): "move:\(transition)"
      case .snooze(let suggestion): "snooze:\(suggestion)"
      case .mute: "mute"
      case .undo(let move): "undo:\(move)"
      case .retry(let transition): "retry:\(transition)"
      case .choose: "choose"
      }
    }

    public init?(id: String) {
      let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
      switch (parts.first, parts.count) {
      case ("mute", 1): self = .mute
      case ("choose", 1): self = .choose
      case ("move", 2): self = .move(parts[1])
      case ("snooze", 2): self = .snooze(parts[1])
      case ("undo", 2): self = .undo(parts[1])
      case ("retry", 2): self = .retry(parts[1])
      default: return nil
      }
    }
  }

  public static func threadKey(_ ticketID: String) -> String { "tickets:\(ticketID)" }

  public static func suggestion(_ suggestion: Suggestion, ticket: Ticket) -> Notice {
    let move = suggestion.target.flatMap { ticket.onlyTransition(to: $0) }
    var actions: [Notice.Action]
    if let move {
      actions = [button(.move(move.id), "Move to \(move.name)"), button(.snooze(suggestion.id), "Not now")]
    } else if suggestion.signal == .stale {
      actions = [button(.snooze(suggestion.id), "Still on it"), button(.choose, "Choose status")]
    } else {
      actions = [button(.choose, "Choose status"), button(.snooze(suggestion.id), "Not now")]
    }
    let more = ticket.transitions.filter { $0 != move }.map { button(.move($0.id), "Move to \($0.name)") }
      + [button(.mute, "Don't ask for this ticket")]
    return Notice(id: "tickets:\(suggestion.id):\(suggestion.evidenceID)", source: .tickets, kind: .ticketSuggestion,
                  title: ticket.key, place: suggestion.evidence, preview: ticket.title, date: suggestion.date,
                  threadKey: threadKey(ticket.id), target: target(ticket),
                  meta: ["ticket": ticket.id, "suggestion": suggestion.id], actions: actions, moreActions: more)
  }

  public static func moved(_ move: TicketMove, ticket: Ticket) -> Notice {
    Notice(id: "tickets:move:\(move.id)", source: .tickets, kind: .ticketMoved, title: move.key,
           place: "Moved to \(move.to)", preview: "\(move.reason) · \(ticket.title)", date: move.date,
           threadKey: threadKey(ticket.id), target: target(ticket), meta: ["ticket": ticket.id, "move": move.id],
           actions: [button(.undo(move.id), "Undo")])
  }

  public static func failed(_ ticket: Ticket, transition: Ticket.Transition, message: String, at date: Date) -> Notice {
    Notice(id: "tickets:failed:\(ticket.id):\(transition.id):\(date.timeIntervalSince1970)", source: .tickets,
           kind: .ticketFailed, title: ticket.key, place: "Couldn't move to \(transition.name)", preview: message,
           date: date, threadKey: threadKey(ticket.id), target: target(ticket), meta: ["ticket": ticket.id],
           actions: [button(.retry(transition.id), "Retry"), button(.choose, "Pick status")])
  }

  public static func morning(summary: String, keys: [String], at date: Date) -> Notice {
    Notice(id: "tickets:morning:\(date.timeIntervalSince1970)", source: .tickets, kind: .ticketsMorning,
           title: "Your top 3 today", place: "Tickets",
           preview: summary.isEmpty ? keys.joined(separator: " · ") : summary, date: date,
           threadKey: "tickets:morning", target: .none)
  }

  public static func checkIn(count: Int, at date: Date) -> Notice {
    Notice(id: "tickets:checkin:\(date.timeIntervalSince1970)", source: .tickets, kind: .ticketsCheckIn,
           title: "You touched \(count) ticket\(count == 1 ? "" : "s") today", place: "Tickets",
           preview: "Check their statuses before you stop.", date: date, threadKey: "tickets:checkin", target: .none)
  }

  private static func button(_ action: Action, _ title: String) -> Notice.Action {
    Notice.Action(id: action.id, title: title)
  }

  private static func target(_ ticket: Ticket) -> Notice.Target { ticket.url.map { .link($0) } ?? .none }
}
