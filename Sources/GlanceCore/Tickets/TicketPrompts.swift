import Foundation

/// Why a tracker run gave nothing usable, in words for the page and the nudges.
public struct TicketFailure: Error, Equatable, Sendable {
  public var message: String

  public init(message: String) { self.message = message }
}

/// The `claude` runs Tickets makes against the user's tracker connectors (spec "Trackers and fetch"): their
/// arguments, prompts and how their JSON answers are read.
public enum TicketPrompts {
  public static let fetchLimit = 50
  public static let fetchTimeout: TimeInterval = 180
  public static let notJSON = "Claude's answer wasn't the JSON Glance asked for."

  /// `claude -p` with JSON out, nothing kept, no hooks, no built-in tools; `tools` (MCP) allowed, or with none the
  /// connectors aren't even loaded. `model` nil is Claude Code's default. `otherServers` are the user's other MCP
  /// servers: denied whole, so their tool definitions stay out of the request (every connector's tools in one request
  /// can overflow the context, "Prompt is too long").
  public static func arguments(tools: [String], model: String?, otherServers: [String] = []) -> [String] {
    var arguments = ["-p", "--output-format", "json", "--no-session-persistence",
                     "--settings", #"{"disableAllHooks":true}"#, "--tools", ""]
    if tools.isEmpty {
      arguments.append("--strict-mcp-config")
    } else {
      arguments += ["--allowedTools", tools.joined(separator: ",")]
    }
    if !tools.isEmpty, !otherServers.isEmpty {
      arguments += ["--disallowedTools", otherServers.map { "mcp__" + TrackerProbe.toolSegment($0) }.joined(separator: ",")]
    }
    if let model { arguments += ["--model", model] }
    return arguments
  }

  public static func fetchPrompt(_ tracker: Tracker, query: String?, now: Date) -> String {
    let find: String
    if let query {
      find = """
        The tickets this query finds (group "query"), used as written (JQL for Jira, a view or filter elsewhere):
        \(query)
        """
    } else {
      find = """
        1. Open tickets assigned to the user (not done, not closed) — group "assigned".
        2. Unassigned open tickets in the user's current sprint or cycle, when the tracker has sprints or cycles — \
        group "upNext".
        """
    }
    return """
      You read the user's issue tracker for Glance with the \(tracker.name) tools (\(tracker.server)). Read only: \
      never create, edit, move, assign or comment on anything.

      Find:
      \(find)

      At most \(fetchLimit) tickets. For each ticket also read the statuses it can move to now (its transitions; for \
      trackers without transitions, the workflow's statuses), and put each status in one category: todo, \
      inProgress, review, done, or unknown.

      Answer with only JSON, no prose:
      {"tickets":[{"key":"ABC-123","title":"…","status":"In Progress","statusCategory":"inProgress",\
      "priority":"High or null","severity":"or null","assignee":"name or null","due":"YYYY-MM-DD or null",\
      "updated":"ISO 8601 or null","url":"https://… or null","sprint":"name or null",\
      "repository":"owner/name for GitHub issues, else null","group":"assigned|upNext|query",\
      "transitions":[{"id":"…","name":"In Review","category":"review"}]}]}
      If you can't reach the tracker, answer {"error":"<why, in one line>"}.
      Today is \(day(now)).
      """
  }

  public static func tickets(from reply: String, tracker: String) -> Result<[Ticket], TicketFailure> {
    guard let object = JournalRecap.jsonObject(in: reply) else { return .failure(TicketFailure(message: notJSON)) }
    if let error = object["error"] as? String { return .failure(TicketFailure(message: error)) }
    guard let items = object["tickets"] as? [[String: Any]] else { return .failure(TicketFailure(message: notJSON)) }
    let tickets = items.prefix(fetchLimit * 2).compactMap { item -> Ticket? in
      guard var key = text(item["key"]), let title = text(item["title"]), let status = text(item["status"]) else {
        return nil
      }
      let repository = text(item["repository"])
      if let repository, key.hasPrefix("#") || Int(key) != nil {
        key = repository + "#" + key.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
      }
      let transitions = (item["transitions"] as? [[String: Any]] ?? []).compactMap { entry -> Ticket.Transition? in
        guard let name = text(entry["name"]) else { return nil }
        return Ticket.Transition(id: text(entry["id"]) ?? name, name: name, category: category(entry["category"]))
      }
      return Ticket(tracker: tracker, key: key, title: title, status: status,
                    statusCategory: category(item["statusCategory"]), priority: text(item["priority"]),
                    severity: text(item["severity"]), assignee: text(item["assignee"]), due: date(item["due"]),
                    updated: date(item["updated"]), url: text(item["url"]).flatMap(URL.init(string:)),
                    sprint: text(item["sprint"]), repository: repository, transitions: transitions,
                    group: text(item["group"]).flatMap(Ticket.Group.init(rawValue:)) ?? .assigned)
    }
    return .success(tickets)
  }

  public static let moveTimeout: TimeInterval = 90

  /// A move run may read (ids, the user's account, transitions) and move; it comments only when asked to.
  public static func moveTools(_ tracker: Tracker, comment: Bool) -> [String] {
    tracker.moveTools + tracker.readTools + (comment ? tracker.commentTools : [])
  }

  public static func movePrompt(_ ticket: Ticket, to transition: Ticket.Transition, assignToMe: Bool,
                                comment: String?, tracker: Tracker) -> String {
    var steps: [String] = []
    if assignToMe { steps.append("Assign it to the user (look up their account first if the tools need it).") }
    let id = transition.id == transition.name ? "" : " (transition id \(transition.id))"
    steps.append("Move it to the status \"\(transition.name)\"\(id).")
    if let comment {
      steps.append("Then add this comment to it, exactly as written between the markers:\n<<<\n\(comment)\n>>>")
    }
    let numbered = steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    return """
      Using the \(tracker.name) tools (\(tracker.server)), change one ticket for the user.
      Ticket: \(ticket.key) — \(ticket.title) (now "\(ticket.status)").
      \(numbered)
      Change nothing else and touch no other ticket.
      Answer with only JSON: {"ok":true,"status":"<the ticket's status now>"} or {"ok":false,"error":"<why, in one line>"}.
      """
  }

  public static func moved(from reply: String) -> Result<String?, TicketFailure> {
    guard let object = JournalRecap.jsonObject(in: reply) else { return .failure(TicketFailure(message: notJSON)) }
    guard object["ok"] as? Bool == true else {
      return .failure(TicketFailure(message: text(object["error"]) ?? "The tracker didn't confirm the move."))
    }
    return .success(text(object["status"]))
  }

  public static let editTimeout: TimeInterval = 90

  /// What Claude proposes for "change this ticket" in the user's words. Only a status move can be carried out, so
  /// that is all it may propose; anything else comes back as a note. No tools: nothing is written until the user
  /// confirms.
  public struct Edit: Equatable, Sendable {
    public var transition: Ticket.Transition?
    public var note: String

    public init(transition: Ticket.Transition?, note: String) {
      self.transition = transition
      self.note = note
    }
  }

  public static func editPrompt(_ ticket: Ticket, request: String) -> String {
    let moves = ticket.transitions.isEmpty
      ? "(none available right now)"
      : ticket.transitions.map { "- id \"\($0.id)\": \($0.name)" }.joined(separator: "\n")
    return """
      The user wants to change a ticket and described it in their own words. Decide what, if anything, Glance can do.
      Ticket: \(ticket.key) — \(ticket.title). Now "\(ticket.status)".
      It can move to:
      \(moves)
      The user said, between the markers:
      <<<
      \(request)
      >>>
      Glance can only move a ticket to one of the statuses above. If the request is a move, pick the matching id.
      Otherwise pick none and say in the note what you couldn't do. Write nothing yourself.
      Answer with only JSON: {"transition":"<id or null>","note":"<one short sentence for the user>"}.
      """
  }

  public static func edit(from reply: String, for ticket: Ticket) -> Result<Edit, TicketFailure> {
    guard let object = JournalRecap.jsonObject(in: reply) else { return .failure(TicketFailure(message: notJSON)) }
    let note = text(object["note"]) ?? ""
    guard let id = text(object["transition"]) else { return .success(Edit(transition: nil, note: note)) }
    guard let transition = ticket.transitions.first(where: { $0.id == id }) else {
      return .success(Edit(transition: nil, note: note.isEmpty ? "That status isn't available for this ticket." : note))
    }
    return .success(Edit(transition: transition, note: note))
  }

  /// Claude Code's "usage limit reached" and "hit your limit · resets …" answers.
  public static func isUsageLimit(_ message: String) -> Bool {
    let lower = message.lowercased()
    return lower.contains("usage limit") || lower.contains("limit reached")
      || (lower.contains("limit") && lower.contains("resets"))
  }

  public static func date(_ value: Any?) -> Date? {
    guard let string = text(value) else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string) { return date }
    let day = DateFormatter()
    day.locale = Locale(identifier: "en_US_POSIX")
    day.dateFormat = "yyyy-MM-dd"
    return day.date(from: string)
  }

  static func text(_ value: Any?) -> String? {
    if let number = value as? NSNumber, !(value is Bool) { return number.stringValue }
    guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty,
          string.lowercased() != "null" else { return nil }
    return string
  }

  static func category(_ value: Any?) -> Ticket.StatusCategory {
    text(value).flatMap(Ticket.StatusCategory.init(rawValue:)) ?? .unknown
  }

  static func day(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }
}
