import Foundation

/// A Glance event an automation can trigger on (spec "Trigger sources", *event*).
public struct AutomationEvent: Equatable, Sendable {
  /// One payload field: `{{trigger.<name>}}` and an event trigger's `filter` key.
  public struct Field: Equatable, Sendable {
    public var name: String
    /// "string" or "number".
    public var type: String
    public var description: String

    public init(_ name: String, _ type: String, _ description: String) {
      self.name = name
      self.type = type
      self.description = description
    }
  }

  public var name: String
  public var description: String
  public var fields: [Field]

  public init(name: String, description: String, fields: [Field]) {
    self.name = name
    self.description = description
    self.fields = fields
  }

  public func field(_ name: String) -> Field? { fields.first { $0.name == name } }
}

/// The event bus catalogue: the single list the validator, the skill's references/events.md and `automation_events`
/// read. A publisher added later goes here first.
public enum AutomationEvents {
  public static let all: [AutomationEvent] = [
    AutomationEvent(name: "meeting.ended", description: "A recorded meeting ended and its notes were written.",
                    fields: [
      .init("meetingID", "string", "The meeting's id in Glance."),
      .init("title", "string", "The meeting's title."),
      .init("notesPath", "string", "The notes file (Markdown)."),
    ]),
    AutomationEvent(name: "notice.new", description: "A new card arrived in the Notifications inbox.", fields: [
      .init("source", "string", "Where it came from: slack, github, meetings, claude, tickets."),
      .init("title", "string", "The card's title."),
      .init("url", "string", "Its link, when it has one."),
    ]),
    AutomationEvent(name: "ticket.moved", description: "Tickets moved a ticket to another status.", fields: [
      .init("key", "string", "The ticket's key (ABC-123)."),
      .init("from", "string", "The status it left."),
      .init("to", "string", "The status it moved to."),
    ]),
    AutomationEvent(name: "pr.ci.failed", description: "A pull request's checks failed.", fields: [
      .init("repo", "string", "owner/name."),
      .init("number", "number", "The pull request's number."),
      .init("sha", "string", "The commit the checks ran on."),
    ]),
    AutomationEvent(name: "journal.closed", description: "The day's journal was closed.", fields: [
      .init("date", "string", "The day, YYYY-MM-DD."),
    ]),
    AutomationEvent(name: "agent.message", description: "An agent sent a message to another agent.", fields: [
      .init("from", "string", "The sending agent's id."),
      .init("to", "string", "The receiving agent's id; filter on your own id."),
      .init("text", "string", "The message."),
      .init("hops", "number", "How many agents have passed it on."),
    ]),
  ]

  public static func named(_ name: String) -> AutomationEvent? { all.first { $0.name == name } }

  /// references/events.md for the Glance skill.
  public static func markdown() -> String {
    var lines = ["# Glance events", "",
                 "Trigger on one with `{ \"kind\": \"event\", \"name\": \"<event>\" }`; add `\"filter\"` to match "
                   + "payload fields exactly. Read a field with `{{trigger.<field>}}`.", ""]
    for event in all {
      lines += ["## `\(event.name)`", "", event.description, "", "| field | type | |", "|---|---|---|"]
      lines += event.fields.map { "| `\($0.name)` | \($0.type) | \($0.description) |" }
      lines.append("")
    }
    return lines.joined(separator: "\n")
  }
}
