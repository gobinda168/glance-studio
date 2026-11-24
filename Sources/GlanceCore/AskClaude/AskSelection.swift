import Foundation

/// Ask Claude about a selection (right-click → Ask Claude, or the Services menu in another app): what the user selected,
/// the prompt that has Claude suggest what to do with it, and its reply. `claude -p` runs with no tools, hooks or MCP
/// servers: it only reads the selection and answers in JSON.
public enum AskSelection {
  /// What a selection can become.
  public enum Kind: String, Codable, Sendable, CaseIterable {
    case ticket, todo, note
  }

  /// A drafted item: the title is one line, the detail the body (a ticket's description, a note's text).
  public struct Draft: Equatable, Sendable {
    public var kind: Kind
    public var title: String
    public var detail: String
    /// A to-do's group, by name, when the user asked for one ("add to my work to-dos").
    public var group: String?

    public init(kind: Kind, title: String, detail: String = "", group: String? = nil) {
      self.kind = kind
      self.title = title
      self.detail = detail
      self.group = group
    }
  }

  public struct Reply: Equatable, Sendable {
    /// Claude's read of the selection, one or two sentences (or the answer to a free-form question).
    public var answer: String
    /// One draft per kind it could write, the one it recommends first.
    public var drafts: [Draft]
    /// What the user asked to have saved straight away: to-dos and notes only, as a ticket needs its site and project
    /// picked in the panel.
    public var actions: [Kind]

    public init(answer: String, drafts: [Draft], actions: [Kind] = []) {
      self.answer = answer
      self.drafts = drafts
      self.actions = actions
    }
  }

  public static let timeout: TimeInterval = 90
  /// The longest selection sent, in characters; a longer one keeps its start and end.
  static let maxSelection = 20_000

  static let systemPrompt = """
    You help someone decide what to do with text they selected on their Mac: in a terminal, a code editor, a chat, a \
    web page or any app. Read it, say what it is in a line, and draft what it could become: a ticket, a to-do or a \
    note. Be concrete and brief. Keep names, numbers, keys, paths and error text exactly as written, and never invent \
    anything the selection doesn't say.
    """

  public static func arguments() -> [String] {
    ["-p", "--output-format", "json", "--no-session-persistence", "--tools", "",
     "--settings", #"{"disableAllHooks":true}"#, "--strict-mcp-config", "--append-system-prompt", systemPrompt]
  }

  /// The prompt: the selection (and where it is from), the drafts to write, and the JSON shape to reply with. A
  /// question the user typed is answered in `answer`, and the drafts follow what they asked for; if it asks to save
  /// a to-do or a note, `do` names them and the panel saves them (into one of `groups`, the to-do groups, by name).
  public static func prompt(selection: String, source: String?, question: String?, groups: [String] = []) -> String {
    var text = "Selected text"
    if let source = source?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty { text += " (from \(source))" }
    text += ":\n\"\"\"\n\(trimmed(selection))\n\"\"\"\n\n"
    let asked = question?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !asked.isEmpty {
      text += "What I want: \(asked)\nAnswer that in \"answer\" (short; Markdown allowed), and draft the items to match.\n"
      text += """
        If it asks to save it as a to-do or a note ("add to my todos", "note this"), list those kinds in "do" and \
        they are saved as you draft them; say in "answer" what you saved. Otherwise leave "do" empty.
        """
      if !groups.isEmpty {
        text += " A to-do can go in one of these groups, by name, when it asks: \(groups.joined(separator: ", "))."
      }
      text += "\n\n"
    } else {
      text += "In \"answer\", say in one or two sentences what this is and what is worth doing with it.\n\n"
    }
    let todo = asked.isEmpty ? #"{"title": "a short imperative, e.g. Reply to Sam about the invoice"}"#
      : #"{"title": "a short imperative, e.g. Reply to Sam about the invoice", "group": "a group's name, or empty"}"#
    text += """
      Reply with only this JSON object:
      {"answer": "...",
       "recommended": "ticket" | "todo" | "note",\(asked.isEmpty ? "" : "\n \"do\": [] or [\"todo\"] or [\"note\"] or both,")
       "ticket": {"title": "one line, under 80 characters", "description": "what, where, how to reproduce or why, from the text only"},
       "todo": \(todo),
       "note": {"title": "a short heading", "text": "the part worth keeping, cleaned up, in Markdown"}}
      Put the kind you'd pick for this text in "recommended". Always fill all three.
      """
    return text
  }

  /// What to save without the user pressing anything: only what Claude says they asked for, and only when they asked.
  public static func actions(_ reply: Reply, asked: String?) -> [Kind] {
    guard let asked, !asked.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
    return reply.actions
  }

  /// Claude's reply, or nil when it holds no usable JSON object.
  public static func parse(_ reply: String) -> Reply? {
    guard let object = JournalRecap.jsonObject(in: reply) else { return nil }
    func text(_ value: Any?) -> String { (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    var drafts: [Draft] = []
    if let ticket = object["ticket"] as? [String: Any], !text(ticket["title"]).isEmpty {
      drafts.append(Draft(kind: .ticket, title: text(ticket["title"]), detail: text(ticket["description"])))
    }
    if let todo = object["todo"] as? [String: Any], !text(todo["title"]).isEmpty {
      let group = text(todo["group"])
      drafts.append(Draft(kind: .todo, title: text(todo["title"]), group: group.isEmpty ? nil : group))
    }
    if let note = object["note"] as? [String: Any], !text(note["title"]).isEmpty || !text(note["text"]).isEmpty {
      drafts.append(Draft(kind: .note, title: text(note["title"]), detail: text(note["text"])))
    }
    let answer = text(object["answer"])
    guard !answer.isEmpty || !drafts.isEmpty else { return nil }
    if let first = Kind(rawValue: text(object["recommended"]).lowercased()),
       let index = drafts.firstIndex(where: { $0.kind == first }) {
      drafts.insert(drafts.remove(at: index), at: 0)
    }
    var actions: [Kind] = []
    for raw in object["do"] as? [Any] ?? [] {
      guard let kind = Kind(rawValue: text(raw).lowercased()), kind != .ticket, !actions.contains(kind),
            drafts.contains(where: { $0.kind == kind }) else { continue }
      actions.append(kind)
    }
    return Reply(answer: answer, drafts: drafts, actions: actions)
  }

  /// The selection as sent: a long one keeps its start and end.
  static func trimmed(_ selection: String) -> String {
    let text = selection.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.count > maxSelection else { return text }
    let half = maxSelection / 2
    return String(text.prefix(half)) + "\n[… middle left out …]\n" + String(text.suffix(half))
  }

  /// A one-line preview of the selection for the panel's header: whitespace collapsed, cut at `limit`.
  public static func preview(_ selection: String, limit: Int = 280) -> String {
    let flat = selection.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard flat.count > limit else { return flat }
    return String(flat.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
  }
}
