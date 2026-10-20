import Foundation

/// The day's recap (spec 2026-10-09-journal-design.md, "The Claude call"): how Claude is run, what it's told, and how
/// its reply becomes a headline, a recap and entries. Claude gets the digest only, with no tools.
public enum JournalRecap {
  public static let timeout: TimeInterval = 180

  public static let systemPrompt = """
    You turn one developer's day into their work journal. You get a digest of the day: Claude Code sessions (what \
    they asked, which files changed), commits, pull requests, reviews, meetings and their own notes, each marked [eN].

    Reply with one JSON object and nothing else:
    {"headline": string, "recap_md": string, "minutes_by_project": {project: minutes}, "entries": [{"title", \
    "summary", "project", "kind", "impact", "challenge", "approach", "outcome", "lesson", "skills", "minutes", \
    "public_draft", "event_refs"}]}

    Rules:
    - Write as the developer, in the first person, plain and specific. No hype, no filler, no emoji.
    - headline: at most 90 characters, the day's main thing.
    - recap_md: 3 to 6 short paragraphs of Markdown: what got done and why it mattered, most important first.
    - entries: 1 to 8 accomplishments. Group related events into one entry. A meeting becomes an entry only when the \
    notes or titles show an outcome.
    - kind: one of shipped, fixed, reviewed, designed, learned, meeting, other.
    - impact: a measured result only when the digest states one (a number, a before and after); otherwise "".
    - challenge, approach, outcome, lesson: one or two sentences each, from the digest; "" when it doesn't say. \
    Never invent numbers, names or results.
    - skills: lowercase tags. Prefer ai, llm, performance, frontend, backend, infra, devops, testing, debugging, \
    product, design, data, security, mobile, docs, review, mentoring; add another only when none fits.
    - minutes: your estimate of the time the entry took, from the active minutes in the digest.
    - public_draft: the same accomplishment in two or three sentences someone outside the company could read: no \
    employer, customer, repository, colleague or internal product names, no file paths.
    - event_refs: the ids of the events the entry comes from, like "e3".
    - project (in entries and minutes_by_project): a project name exactly as the digest's headings write it.
    """

  public static func arguments() -> [String] {
    ["-p", "--output-format", "json", "--no-session-persistence", "--tools", "",
     "--settings", #"{"disableAllHooks":true}"#, "--strict-mcp-config", "--append-system-prompt", systemPrompt]
  }

  public static func prompt(_ digest: JournalDigest) -> String {
    digest.text + "\n\nWrite this day's journal now. Reply with the JSON object only."
  }

  public struct Draft: Equatable, Sendable {
    public var headline: String
    public var recap: String
    public var minutesByProject: [String: Int]
    public var entries: [JournalEntry]
  }

  public struct Failure: Error, Equatable, Sendable {
    public let message: String

    public init(message: String) {
      self.message = message
    }
  }

  static let maxEntries = 8
  static let maxSkills = 8
  static let maxMinutes = 960

  public static func parse(_ reply: String, day: JournalDay, digest: JournalDigest, now: Date,
                           makeID: () -> String = { UUID().uuidString }) -> Result<Draft, Failure> {
    guard let object = jsonObject(in: reply) else { return .failure(Failure(message: "Claude's reply wasn't JSON.")) }
    let headline = JournalText.clean(object["headline"] as? String ?? "", limit: 90)
    let recap = JournalText.trim(object["recap_md"] as? String ?? "", limit: 6000)
    guard !headline.isEmpty, !recap.isEmpty else { return .failure(Failure(message: "Claude's reply had no recap.")) }
    var minutes: [String: Int] = [:]
    for (name, value) in object["minutes_by_project"] as? [String: Any] ?? [:] {
      guard let number = value as? NSNumber else { continue }
      minutes[digest.projects[name] ?? name] = clamp(number.intValue)
    }
    var entries: [JournalEntry] = []
    for item in (object["entries"] as? [[String: Any]] ?? []) where entries.count < maxEntries {
      func text(_ key: String, _ limit: Int) -> String { JournalText.clean(item[key] as? String ?? "", limit: limit) }
      let title = text("title", 80)
      guard !title.isEmpty else { continue }
      let project = (item["project"] as? String).map { digest.projects[$0] ?? $0 }.map { JournalText.clean($0, limit: 200) }
      var seen = Set<String>()
      let skills = (item["skills"] as? [Any] ?? []).compactMap { $0 as? String }
        .map { JournalText.clean($0.lowercased(), limit: 24) }
        .filter { !$0.isEmpty && seen.insert($0).inserted }
      let refs = (item["event_refs"] as? [Any] ?? []).compactMap { $0 as? String }
        .compactMap { digest.refs[$0.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))] }
      entries.append(JournalEntry(
        id: makeID(), day: day, position: entries.count, title: title, summary: text("summary", 400),
        project: project?.isEmpty == false ? project : nil,
        kind: (item["kind"] as? String).flatMap { JournalEntry.Kind(rawValue: $0.lowercased()) } ?? .other,
        impact: text("impact", 200), challenge: text("challenge", 600), approach: text("approach", 600),
        outcome: text("outcome", 600), lesson: text("lesson", 600), skills: Array(skills.prefix(maxSkills)),
        minutes: clamp((item["minutes"] as? NSNumber)?.intValue ?? 0), publicDraft: text("public_draft", 600),
        eventIDs: refs, createdAt: now))
    }
    return .success(Draft(headline: headline, recap: recap, minutesByProject: minutes, entries: entries))
  }

  /// A redraft's entries: the ones the user edited or added first, in their order, then the new draft's.
  public static func merge(existing: [JournalEntry], draft: [JournalEntry]) -> [JournalEntry] {
    let kept = existing.filter(\.edited).sorted { $0.position < $1.position }
    return (kept + draft).enumerated().map { index, entry in
      var entry = entry
      entry.position = index
      return entry
    }
  }

  private static func clamp(_ minutes: Int) -> Int { min(max(minutes, 0), maxMinutes) }

  /// The JSON object in a reply: inside a ``` fence when there is one, else from the first "{" to the last "}". The
  /// fence closes at the last ```, since a value (a Markdown answer) can hold code blocks of its own.
  static func jsonObject(in reply: String) -> [String: Any]? {
    let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
    if let fence = text.range(of: "```") {
      let body = text[fence.upperBound...].drop { $0 != "\n" }
      if let close = body.range(of: "```", options: .backwards), let object = object(in: body[..<close.lowerBound]) {
        return object
      }
    }
    return object(in: Substring(text))
  }

  private static func object(in text: Substring) -> [String: Any]? {
    guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close else { return nil }
    return try? JSONSerialization.jsonObject(with: Data(text[open...close].utf8)) as? [String: Any]
  }
}
