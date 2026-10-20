import Foundation

/// "This ticket's status looks out of date": a signal, its evidence, and the category it should move to (nil: the
/// user chooses, as for a stale ticket).
public struct Suggestion: Codable, Equatable, Identifiable, Sendable {
  public var ticketID: String
  public var signal: TicketSignal
  public var target: Ticket.StatusCategory?
  /// What the user reads: "PR #412 merged", "Commit a1b2c3d · Fix login".
  public var evidence: String
  /// What makes this evidence new: "commit:<hash>", "pr:acme/api#412:merged", "session:<file>", "stale:<since>".
  public var evidenceID: String
  public var link: URL?
  public var date: Date

  /// One pending suggestion per ticket and target.
  public var id: String { "\(ticketID)>\(target?.rawValue ?? "choose")" }

  public init(ticketID: String, signal: TicketSignal, target: Ticket.StatusCategory?, evidence: String,
              evidenceID: String, link: URL?, date: Date) {
    self.ticketID = ticketID
    self.signal = signal
    self.target = target
    self.evidence = evidence
    self.evidenceID = evidenceID
    self.link = link
    self.date = date
  }
}

/// The suggestions waiting on the user, and what they said: Not now (until new evidence), Don't ask for this ticket,
/// and the tickets whose auto move failed (they ask until a move succeeds).
public struct SuggestionState: Codable, Equatable, Sendable {
  public private(set) var pending: [Suggestion] = []
  /// Suggestion id → the evidence it was snoozed with.
  public private(set) var snoozed: [String: String] = [:]
  public private(set) var muted: Set<String> = []
  public private(set) var autoBlocked: Set<String> = []

  public init() {}

  /// Adds `suggestion`. False when one with the same id was already pending: its evidence is replaced, and nobody
  /// needs nudging again.
  public mutating func add(_ suggestion: Suggestion) -> Bool {
    if let index = pending.firstIndex(where: { $0.id == suggestion.id }) {
      pending[index] = suggestion
      return false
    }
    pending.append(suggestion)
    return true
  }

  public mutating func snooze(_ id: String) {
    guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
    snoozed[id] = pending[index].evidenceID
    pending.remove(at: index)
  }

  /// The ticket moved (or the user picked a status): nothing about it is pending any more.
  public mutating func resolve(ticketID: String) {
    pending.removeAll { $0.ticketID == ticketID }
  }

  public mutating func mute(_ ticketID: String) {
    muted.insert(ticketID)
    resolve(ticketID: ticketID)
  }

  public mutating func setAutoBlocked(_ ticketID: String, _ blocked: Bool) {
    if blocked { autoBlocked.insert(ticketID) } else { autoBlocked.remove(ticketID) }
  }

  public func pending(for ticketID: String) -> [Suggestion] { pending.filter { $0.ticketID == ticketID } }

  public func isSnoozed(_ suggestion: Suggestion) -> Bool { snoozed[suggestion.id] == suggestion.evidenceID }
}
