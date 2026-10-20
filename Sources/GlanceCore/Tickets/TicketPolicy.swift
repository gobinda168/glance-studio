import Foundation

/// What happens to a suggestion (spec "Policy"): dropped (switched off, muted, snoozed, or the ticket is already
/// there), moved on its own (Auto, forward, exactly one transition, not seeding, no failed auto move pending), or a
/// nudge for the user.
public enum TicketPolicy {
  public enum Decision: Equatable, Sendable {
    case auto(Ticket.Transition)
    case nudge
    case drop
  }

  public static func decide(_ suggestion: Suggestion, ticket: Ticket, prefs: TicketPrefs, state: SuggestionState,
                            seeding: Bool) -> Decision {
    let mode = prefs.mode(suggestion.signal)
    guard mode != .off, !state.muted.contains(ticket.id), !state.isSnoozed(suggestion) else { return .drop }
    if let target = suggestion.target {
      if ticket.statusCategory == target { return .drop }
      if let current = ticket.statusCategory.step, let goal = target.step, current >= goal { return .drop }
    }
    guard mode == .auto, !seeding, !state.autoBlocked.contains(ticket.id), let target = suggestion.target,
          isForward(from: ticket.statusCategory, to: target),
          let transition = ticket.onlyTransition(to: target) else { return .nudge }
    return .auto(transition)
  }

  public static func isForward(from: Ticket.StatusCategory, to: Ticket.StatusCategory) -> Bool {
    guard let from = from.step, let to = to.step else { return false }
    return to > from
  }
}
