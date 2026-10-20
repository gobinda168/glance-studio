import Foundation

/// Claude's daily order (spec "Ranking"): the prompt — the user's instructions or the default, then the tickets,
/// then Glance's JSON contract, so a custom prompt can't change the answer's shape — its parsing, and the plain order
/// used when there's no rank.
public enum TicketRanking {
  public static let timeout: TimeInterval = 120
  public static let maxPickUp = 3

  public static let defaultInstructions = """
    Order the user's tickets for today, the one to work on first at the top:
    1. Blockers and the highest severity first (incidents, bugs hurting users, anything blocking other people).
    2. Then priority, highest first.
    3. Then due date: overdue first, then the soonest.
    4. Then tickets already in progress or in review before ones not started.
    Give each ticket one short reason (under 12 words) saying why it sits where it does.
    From the "upNext" tickets pick at most 3 the user could pick up next, each with a short reason.
    """

  static let contract = """
    Answer with only JSON, no prose, in exactly this shape. Every "assigned" or "query" ticket goes in "order"; only \
    "upNext" tickets go in "pickUp":
    {"order":[{"key":"ABC-1","reason":"…"}],"pickUp":[{"key":"ABC-9","reason":"…"}],\
    "summary":"one short paragraph: what today looks like"}
    """

  public struct Ranked: Equatable, Identifiable, Sendable {
    public var ticket: Ticket
    public var reason: String?
    public var id: String { ticket.id }

    public init(ticket: Ticket, reason: String?) {
      self.ticket = ticket
      self.reason = reason
    }
  }

  public struct Arranged: Equatable, Sendable {
    public var today: [Ranked]
    public var upNext: [Ranked]
    /// False: no rank yet (or it failed): the plain order, labelled "not ranked".
    public var ranked: Bool
  }

  public static func prompt(tickets: [Ticket], evidence: [String: [String]], instructions: String, now: Date)
    -> String {
    let custom = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    var lines = [custom.isEmpty ? defaultInstructions : custom, "", "Today is \(TicketPrompts.day(now)).", "",
                 "Tickets, one per line: key · title · status · priority · severity · due · updated · group · "
                   + "what Glance saw:"]
    for ticket in tickets where ticket.statusCategory != .done {
      let seen = (evidence[ticket.id] ?? []).joined(separator: "; ")
      let fields = [ticket.key, ticket.title, "\(ticket.status) (\(ticket.statusCategory.rawValue))",
                    ticket.priority ?? "-", ticket.severity ?? "-", ticket.due.map(TicketPrompts.day) ?? "-",
                    ticket.updated.map(TicketPrompts.day) ?? "-", ticket.group.rawValue, seen.isEmpty ? "-" : seen]
      lines.append("- " + fields.joined(separator: " · "))
    }
    lines += ["", contract]
    return lines.joined(separator: "\n")
  }

  public static func parse(_ reply: String, tickets: [Ticket], at date: Date) -> TicketRank? {
    guard let object = JournalRecap.jsonObject(in: reply), let order = object["order"] as? [[String: Any]] else {
      return nil
    }
    var byKey: [String: Ticket] = [:]
    for ticket in tickets where byKey[ticket.key.uppercased()] == nil { byKey[ticket.key.uppercased()] = ticket }
    func lines(_ items: [[String: Any]], upNext: Bool) -> [TicketRank.Line] {
      var seen = Set<String>()
      return items.compactMap { item in
        guard let key = TicketPrompts.text(item["key"])?.uppercased(), let ticket = byKey[key],
              (ticket.group == .upNext) == upNext, seen.insert(key).inserted else { return nil }
        return TicketRank.Line(key: ticket.key, reason: TicketPrompts.text(item["reason"]) ?? "")
      }
    }
    let ranked = lines(order, upNext: false)
    guard !ranked.isEmpty || !tickets.contains(where: { $0.group != .upNext }) else { return nil }
    let pickUp = lines(object["pickUp"] as? [[String: Any]] ?? [], upNext: true)
    return TicketRank(order: ranked, pickUp: Array(pickUp.prefix(maxPickUp)),
                      summary: TicketPrompts.text(object["summary"]) ?? "", date: date)
  }

  /// 0 for blockers/highest/critical/urgent … 4 for lowest/trivial; 5 when unknown.
  public static func urgency(_ value: String?) -> Int {
    guard let value = value?.lowercased() else { return 5 }
    let levels: [[String]] = [
      ["blocker", "highest", "critical", "urgent", "p0", "sev1", "sev-1"],
      ["high", "major", "p1", "sev2", "sev-2"],
      ["medium", "normal", "p2", "sev3", "sev-3"],
    ]
    for (index, words) in levels.enumerated() where words.contains(where: value.contains) { return index }
    if ["lowest", "trivial", "p4"].contains(where: value.contains) { return 4 }
    if ["low", "minor", "p3"].contains(where: value.contains) { return 3 }
    return 5
  }

  /// Urgency (the more urgent of severity and priority), then due date (none last), then started before not started,
  /// then most recently updated, then key.
  public static func fallback(_ tickets: [Ticket]) -> [Ticket] {
    func started(_ ticket: Ticket) -> Bool { ticket.statusCategory == .inProgress || ticket.statusCategory == .review }
    return tickets.sorted { a, b in
      let ua = min(urgency(a.severity), urgency(a.priority)), ub = min(urgency(b.severity), urgency(b.priority))
      if ua != ub { return ua < ub }
      if a.due != b.due { return (a.due ?? .distantFuture) < (b.due ?? .distantFuture) }
      if started(a) != started(b) { return started(a) }
      if a.updated != b.updated { return (a.updated ?? .distantPast) > (b.updated ?? .distantPast) }
      return a.key < b.key
    }
  }

  /// Today (assigned + query) and Up next, done tickets left out: the rank's tickets first in its order, then the
  /// rest in the plain order.
  public static func arrange(_ tickets: [Ticket], rank: TicketRank?) -> Arranged {
    let open = tickets.filter { $0.statusCategory != .done }
    func place(_ group: [Ticket], _ lines: [TicketRank.Line]) -> [Ranked] {
      var rest = group
      var placed: [Ranked] = []
      for line in lines {
        guard let index = rest.firstIndex(where: { $0.key.caseInsensitiveCompare(line.key) == .orderedSame }) else {
          continue
        }
        placed.append(Ranked(ticket: rest.remove(at: index), reason: line.reason.isEmpty ? nil : line.reason))
      }
      return placed + fallback(rest).map { Ranked(ticket: $0, reason: nil) }
    }
    return Arranged(today: place(open.filter { $0.group != .upNext }, rank?.order ?? []),
                    upNext: place(open.filter { $0.group == .upNext }, rank?.pickUp ?? []),
                    ranked: rank != nil)
  }

  /// What Read aloud says at the morning card.
  public static func spoken(top: [Ranked], summary: String, name: String?) -> String {
    let greeting = name.map { "Good morning \($0)." } ?? "Good morning."
    guard !top.isEmpty else { return greeting + " Nothing is assigned to you today." }
    var parts = [greeting]
    let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { parts.append(trimmed) }
    for (index, item) in top.enumerated() {
      parts.append("\(index == 0 ? "First," : "Then") \(item.ticket.key): \(item.ticket.title).")
    }
    return parts.joined(separator: " ")
  }
}
