import Foundation

/// Slack's own notifications as notices (spec 2026-10-09-notifications-design.md, "Sources → Slack"). The Studio's
/// `SlackNoticeBridge` catches every `new Notification(…)` / `showNotification(…)` in a workspace's page and posts its
/// title and options here. Slack's titles: "<sender>" for a DM, "<sender> in #channel", "New message in #channel",
/// "Thread in #channel", sometimes "New message from <sender>" or "<sender> (#channel)"; the body may begin
/// "<sender>: ".
public enum SlackNotices {
  /// What the page's notification said: `{id, title, body, tag, icon}` from the `glanceNotice` message handler.
  public struct Payload: Equatable, Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let tag: String?
    public let icon: String?

    public init(id: String, title: String, body: String, tag: String?, icon: String?) {
      self.id = id
      self.title = title
      self.body = body
      self.tag = tag
      self.icon = icon
    }

    /// From the message body (a dictionary from WebKit): a String `title` is required; `body` defaults to "", `id` to
    /// a new UUID; `tag` and `icon` are kept when they're non-empty strings. Nil for anything else, or when the title
    /// and body are both empty.
    public init?(_ body: Any) {
      guard let object = body as? [String: Any], let title = object["title"] as? String else { return nil }
      let text = object["body"] as? String ?? ""
      guard !(title + text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
      let id = (object["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
      self.init(id: id, title: title, body: text, tag: Self.string(object["tag"]), icon: Self.string(object["icon"]))
    }

    private static func string(_ value: Any?) -> String? {
      guard let text = value as? String, !text.isEmpty else { return nil }
      return text
    }
  }

  /// The notice for one of `team`'s notifications. `workspace` (its name) goes into `meta["workspace"]`, which the
  /// quick-reply prompts use.
  public static func notice(_ payload: Payload, team: String, workspace: String?, at date: Date) -> Notice {
    let parsed = parse(title: payload.title)
    var sender = parsed.sender
    var text = payload.body.trimmingCharacters(in: .whitespacesAndNewlines)
    if sender == nil, let (name, rest) = senderPrefix(text) {
      sender = name
      text = rest
    }
    let kind: Notice.Kind
    if parsed.thread {
      kind = .slackThread
    } else if parsed.channel == nil {
      kind = .slackDM
    } else if text.contains("@") || text.localizedCaseInsensitiveContains("mentioned you") {
      kind = .slackMention
    } else {
      kind = .slackChannel
    }
    let place = parsed.channel ?? "DM"
    let title = sender ?? parsed.channel ?? "Slack"
    let threadKey: String
    if let tag = payload.tag {
      threadKey = "slack:\(team):\(tag)"
    } else if let channel = parsed.channel {
      threadKey = "slack:\(team):\(channel)"
    } else {
      threadKey = "slack:\(team):DM:\(title)"
    }
    var meta: [String: String] = [:]
    if let workspace, !workspace.isEmpty { meta["workspace"] = workspace }
    let avatar = payload.icon.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
    return Notice(id: "slack:\(team):\(payload.id):\(date.timeIntervalSince1970)", source: .slack, kind: kind,
                  title: title, place: place, preview: text, date: date, threadKey: threadKey,
                  target: .slack(team: team, notificationID: payload.id, channel: nil),
                  people: sender.map { [$0] } ?? [], avatarURL: avatar, meta: meta)
  }

  private struct Title {
    var sender: String?
    var channel: String?
    var thread = false
  }

  /// The sender and channel a title names, and whether it's a thread's.
  private static func parse(title raw: String) -> Title {
    var rest = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    var result = Title()
    if let stripped = strip("Thread in ", from: rest) {
      result.thread = true
      rest = stripped
    } else if let stripped = strip("New message in ", from: rest) {
      rest = stripped
    } else if let stripped = strip("New message from ", from: rest) {
      result.sender = nonEmpty(stripped)
      return result
    }
    if rest.hasPrefix("#") {
      // "#infra"
      result.channel = nonEmpty(rest)
    } else if let range = rest.range(of: " in #", options: .backwards) {
      // "Riya Sharma in #infra"
      result.sender = nonEmpty(String(rest[..<range.lowerBound]))
      result.channel = nonEmpty("#" + rest[range.upperBound...])
    } else if rest.hasSuffix(")"), let open = rest.range(of: " (#", options: .backwards) {
      // "Riya Sharma (#infra)"
      result.sender = nonEmpty(String(rest[..<open.lowerBound]))
      result.channel = nonEmpty("#" + rest[open.upperBound...].dropLast())
    } else {
      // A DM: the title is the sender.
      result.sender = nonEmpty(rest)
    }
    return result
  }

  /// "Riya Sharma: deploy now?" → ("Riya Sharma", "deploy now?"). A name is one line of at most 80 characters.
  private static func senderPrefix(_ body: String) -> (String, String)? {
    guard let colon = body.range(of: ": ") else { return nil }
    let name = body[..<colon.lowerBound].trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty, name.count <= 80, !name.contains("\n") else { return nil }
    return (name, String(body[colon.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private static func strip(_ prefix: String, from text: String) -> String? {
    guard text.hasPrefix(prefix) else { return nil }
    return String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
  }

  private static func nonEmpty(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? nil : trimmed
  }
}
