import Foundation

/// The quick-reply panel's words for Claude (spec 2026-10-09-notifications-design.md, "Quick-reply panel"): the AI
/// chips' prompt, the Slack resolve and send prompts, and the parsers for what comes back. Nothing here sends: a send
/// prompt is only run when the user presses Send.
public enum QuickReply {
  public enum Action: String, Sendable { case summarise, analyse, draft, refine }

  public struct Message: Equatable, Sendable {
    public let author: String
    public let text: String
    public let ts: String?

    public init(author: String, text: String, ts: String?) {
      self.author = author
      self.text = text
      self.ts = ts
    }
  }

  /// A Slack message found by a resolve run, with the thread around it (oldest first).
  public struct SlackThread: Equatable, Sendable {
    public let channel: String
    public let ts: String
    public let threadTS: String?
    public let permalink: String?
    public let messages: [Message]

    public init(channel: String, ts: String, threadTS: String?, permalink: String?, messages: [Message]) {
      self.channel = channel
      self.ts = ts
      self.threadTS = threadTS
      self.permalink = permalink
      self.messages = messages
    }

    /// The thread a reply goes into: the thread's root, or the message itself when it has no thread yet.
    public var replyTS: String { threadTS ?? ts }
  }

  /// The prompt for an AI chip: the notice, the thread text we have, and for Slack the instruction to read more with
  /// the Slack tools.
  public static func prompt(_ action: Action, notice: Notice, thread: [Message], canReadSlack: Bool) -> String {
    var lines = ["You help the user handle one notification in Glance. Source: \(notice.source.title)."
      + (workspace(notice).map { " Workspace: \($0)." } ?? "")]
    lines.append("From: " + [notice.title, notice.place, iso(notice.date)].compactMap { $0 }.joined(separator: " · "))
    lines.append("Notification text: \(notice.preview)")
    lines.append("Thread so far:")
    if thread.isEmpty {
      lines.append("(only the notification text)")
    } else {
      lines += thread.map { "\($0.author): \($0.text)" }
    }
    lines.append(canReadSlack
      ? "You may read more of this Slack conversation with the Slack tools (search for it by the people, channel and "
        + "text above). Never post, react or change anything."
      : "Use only the text above.")
    lines.append("Task: " + task(action))
    lines.append("Do not send anything.")
    return lines.joined(separator: "\n")
  }

  /// The prompt for "Ask Claude" under the composer: the user's instruction applied to the text in the composer (which
  /// may be empty: then the instruction says what to write). The answer replaces the composer's text; the user sees it
  /// there before pressing Send.
  public static func refinePrompt(notice: Notice, thread: [Message], draft: String, instruction: String,
                                  canReadSlack: Bool) -> String {
    var lines = [prompt(.refine, notice: notice, thread: thread, canReadSlack: canReadSlack)]
    let current = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    lines.append("The user's reply so far (between the markers): <<<\n" + (current.isEmpty ? "(nothing yet)" : current)
      + "\n>>>")
    lines.append("The user asks: \(instruction)")
    lines.append("Answer with only the full text of the reply as it should be sent, no preamble, no quotes, no "
      + "notes. Keep what the user wrote unless the request changes it; keep their language and voice.")
    return lines.joined(separator: "\n")
  }

  /// Finds a Slack notice's message and its thread (model haiku, the Slack read tools only).
  public static func resolvePrompt(_ notice: Notice) -> String {
    let facts = [workspace(notice).map { "Workspace: \($0)" }, "from: \(notice.title)",
                 notice.place.map { "in: \($0)" }, "around: \(iso(notice.date))", "text: \(notice.preview)"]
    return "Find this Slack message with the Slack tools and read its thread. "
      + facts.compactMap { $0 }.joined(separator: "; ") + ". Answer with only JSON:\n"
      + #"{"channel":"<id>","ts":"<message ts>","thread_ts":"<thread ts or null>","permalink":"<url or null>","messages":[{"author":"…","text":"…","ts":"…"}]}"#
      + "\nwith up to 15 messages of the thread, oldest first. If you can't find it answer "
      + #"{"error":"not found"}"# + ". Never post, react or change anything."
  }

  /// Posts the user's text, unchanged, as a thread reply (model haiku, the Slack send tool only). Run only on Send.
  public static func sendPrompt(text: String, channel: String, threadTS: String) -> String {
    "Post exactly this message, unchanged, as a reply in Slack channel \(channel) in the thread with ts \(threadTS), "
      + "using the Slack send tool once. Message (between the markers): <<<\n\(text)\n>>>. Then answer with only JSON "
      + #"{"ok":true,"permalink":"<url or null>"}, or {"ok":false,"error":"…"} if it failed. Do nothing else."#
  }

  /// A resolve run's answer; nil without a `channel` and `ts` (`{"error":"not found"}`, prose).
  public static func slackThread(from text: String) -> SlackThread? {
    guard let object = ClaudeJSON.object(in: text),
          let channel = string(object["channel"]), let ts = string(object["ts"]) else { return nil }
    let messages = (object["messages"] as? [[String: Any]] ?? []).compactMap { message -> Message? in
      guard let body = message["text"] as? String else { return nil }
      return Message(author: string(message["author"]) ?? "Someone", text: body, ts: string(message["ts"]))
    }
    return SlackThread(channel: channel, ts: ts, threadTS: string(object["thread_ts"]),
                       permalink: string(object["permalink"]), messages: messages)
  }

  /// A send run's answer: `ok` only when Claude said `"ok": true`.
  public static func sent(from text: String) -> (ok: Bool, permalink: String?) {
    guard let object = ClaudeJSON.object(in: text), object["ok"] as? Bool == true else { return (false, nil) }
    return (true, string(object["permalink"]))
  }

  /// Text after a "Draft:" style preamble removed; trimmed.
  public static func draftText(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var lines = trimmed.components(separatedBy: "\n")
    if let first = lines.first, isPreamble(first) { lines.removeFirst() }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: Helpers

  private static func task(_ action: Action) -> String {
    switch action {
    case .summarise: "Summarise the thread in 2–4 short bullet points: what's being asked and what's decided."
    case .analyse:
      "Analyse it: what does the sender need from the user, how urgent is it, and what's the best response? "
        + "Under 120 words."
    case .draft:
      "Draft the user's reply: short, friendly, in the thread's tone and language. Reply with only the message text, "
        + "no preamble."
    case .refine:
      "Change the user's reply the way they ask, using the thread for context. Do not send anything."
    }
  }

  private static func workspace(_ notice: Notice) -> String? {
    notice.meta["workspace"].flatMap { $0.isEmpty ? nil : $0 }
  }

  private static func iso(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }

  /// A non-empty string that isn't Claude's "null" written as text.
  private static func string(_ value: Any?) -> String? {
    guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty, text.lowercased() != "null" else { return nil }
    return text
  }

  /// "Draft:", "Reply:" (any case, bold or not) or "Here's your reply…".
  private static func isPreamble(_ line: String) -> Bool {
    let bare = line.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "*_#")))
      .lowercased()
    return bare == "draft:" || bare == "reply:" || bare.hasPrefix("here's") || bare.hasPrefix("here’s")
  }
}
