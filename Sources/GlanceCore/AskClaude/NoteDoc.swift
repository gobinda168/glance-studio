import Foundation

/// A note in To-dos & Notes, laid out like Eraser: a Markdown document beside its diagrams. Each diagram is Mermaid
/// code (diagram-as-code) with Claude's explanation under it. Kept as one JSON file per note.
public struct NoteDoc: Codable, Equatable, Identifiable, Sendable {
  public struct Diagram: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var code: String
    public var explanation: String
    /// What the user asked Claude for, when Claude drew it.
    public var prompt: String?
    public var created: Date

    public init(id: UUID = UUID(), title: String, code: String, explanation: String = "", prompt: String? = nil,
                created: Date = Date()) {
      self.id = id
      self.title = title
      self.code = code
      self.explanation = explanation
      self.prompt = prompt
      self.created = created
    }
  }

  public var id: UUID
  public var title: String
  /// The document, in Markdown.
  public var body: String
  public var diagrams: [Diagram]
  public var created: Date
  public var updated: Date
  /// Where its text was selected ("Terminal", "Safari"), when Ask Claude made it.
  public var source: String?

  public init(id: UUID = UUID(), title: String = "", body: String = "", diagrams: [Diagram] = [],
              created: Date = Date(), updated: Date? = nil, source: String? = nil) {
    self.id = id
    self.title = title
    self.body = body
    self.diagrams = diagrams
    self.created = created
    self.updated = updated ?? created
    self.source = source
  }

  /// The title as listed: the title, else the document's first line, else "Untitled".
  public var displayTitle: String {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !title.isEmpty { return title }
    let first = body.split(whereSeparator: \.isNewline).first.map {
      String($0).trimmingCharacters(in: CharacterSet(charactersIn: "#>-* ").union(.whitespaces))
    } ?? ""
    return first.isEmpty ? "Untitled" : String(first.prefix(60))
  }

  /// The document and its diagrams as one Markdown file (each diagram a ```mermaid block), for export.
  public var markdown: String {
    var text = "# \(displayTitle)\n\n"
    let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
    if !body.isEmpty { text += body + "\n" }
    for diagram in diagrams {
      text += "\n## \(diagram.title.isEmpty ? "Diagram" : diagram.title)\n\n```mermaid\n\(diagram.code)\n```\n"
      let explanation = diagram.explanation.trimmingCharacters(in: .whitespacesAndNewlines)
      if !explanation.isEmpty { text += "\n\(explanation)\n" }
    }
    return text
  }

  /// Quick note's Add to: `body` with `text` at its end, under a "— 16 Oct, 14:32 · from Safari" line.
  public static func appending(_ text: String, to body: String, source: String?, at date: Date = Date(),
                               timeZone: TimeZone = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "d MMM, HH:mm"
    var stamp = "— " + formatter.string(from: date)
    if let source, !source.isEmpty { stamp += " · from \(source)" }
    let added = stamp + "\n\n" + text.trimmingCharacters(in: .whitespacesAndNewlines)
    let kept = body.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    return kept.isEmpty ? added : kept + "\n\n" + added
  }

  /// The notes the old single Notes.md held, one note each (oldest last, as they were written).
  public static func imported(from notesFile: String, now: Date = Date()) -> [NoteDoc] {
    Captures.entries(in: notesFile).enumerated().map { index, entry in
      // Keep their order: the file's first entry is the newest.
      let date = now.addingTimeInterval(-Double(index))
      return NoteDoc(title: entry.title == "Note" ? "" : entry.title, body: entry.text, created: date)
    }
  }
}

/// Claude drawing a note's diagram: `claude -p` with no tools, hooks or MCP, the note, what the user asked for (and the
/// diagram to revise, if any), and one JSON object back.
public enum NoteDiagramPrompt {
  public static let timeout: TimeInterval = 120
  static let maxBody = 30_000

  /// One-tap asks, shown when a note has no diagram yet.
  public static let suggestions = ["Flowchart of the steps", "Sequence of who talks to whom", "Mind map of the ideas",
                                   "Architecture of the parts"]

  static let systemPrompt = """
    You draw diagrams for notes, as Mermaid code, and explain them. Use only Mermaid syntax that Mermaid 11 renders: \
    flowchart, sequenceDiagram, classDiagram, stateDiagram-v2, erDiagram, mindmap, timeline, gantt or pie. Keep \
    labels short, quote any label with punctuation, and never invent facts the note doesn't contain.
    """

  public static func arguments() -> [String] {
    ["-p", "--output-format", "json", "--no-session-persistence", "--tools", "",
     "--settings", #"{"disableAllHooks":true}"#, "--strict-mcp-config", "--append-system-prompt", systemPrompt]
  }

  /// `request`: what the user asked for (blank: the note's main idea). `revising`: the diagram to change.
  /// `renderError`: Mermaid's error for that diagram, when the ask is to fix it.
  public static func prompt(note: NoteDoc, request: String, revising: NoteDoc.Diagram? = nil,
                            renderError: String? = nil) -> String {
    var body = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
    if body.count > maxBody { body = String(body.prefix(maxBody)) + "\n[… rest left out …]" }
    var text = "Note: \(note.displayTitle)\n\"\"\"\n\(body.isEmpty ? "(empty)" : body)\n\"\"\"\n\n"
    if let revising {
      text += "Current diagram (\(revising.title)):\n```mermaid\n\(revising.code)\n```\n\n"
      if let renderError, !renderError.isEmpty {
        text += "Mermaid can't render it: \(renderError)\nFix the code so it renders, keeping what it shows.\n\n"
      }
    }
    let ask = request.trimmingCharacters(in: .whitespacesAndNewlines)
    text += ask.isEmpty
      ? "Draw the diagram that best explains this note.\n\n"
      : "\(revising == nil ? "Draw" : "Change the diagram"): \(ask)\n\n"
    text += """
      Reply with only this JSON object:
      {"title": "a short name for the diagram",
       "mermaid": "the Mermaid code, without a code fence",
       "explanation": "2-5 sentences or a short list in Markdown: what the diagram shows and what to notice"}
      """
    return text
  }

  /// The diagram from Claude's reply (its code unfenced), or nil when there's no usable code.
  public static func parse(_ reply: String) -> (title: String, code: String, explanation: String)? {
    guard let object = JournalRecap.jsonObject(in: reply) else { return nil }
    func text(_ key: String) -> String {
      (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    let code = unfenced(text("mermaid"))
    guard !code.isEmpty else { return nil }
    return (text("title").isEmpty ? "Diagram" : text("title"), code, text("explanation"))
  }

  /// Code with a ``` fence around it loses the fence.
  static func unfenced(_ code: String) -> String {
    var lines = code.components(separatedBy: "\n")
    guard lines.first?.hasPrefix("```") == true else { return code }
    lines.removeFirst()
    if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
