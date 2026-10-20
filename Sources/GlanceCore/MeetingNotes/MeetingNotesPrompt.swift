import Foundation

/// Claude Code's part (spec 2026-10-09-meeting-notes-design.md, "MeetingNotesPrompt"): `claude -p` with no tools, no
/// hooks and no MCP servers, the notes prompt and its JSON, and the Ask prompt. Only the transcript text is sent.
public enum MeetingNotesPrompt {
  public static let timeout: TimeInterval = 240
  public static let askTimeout: TimeInterval = 120
  /// The longest transcript sent, in characters; a longer one keeps its start and end.
  static let maxTranscript = 400_000

  static let systemPrompt = """
    You write meeting notes from a transcript. The transcript comes from on-device speech recognition, so expect \
    misheard words and fix them from context. "You" (or the user's name) is the person you're writing for. Be \
    concrete and brief: names, numbers, dates, owners. Never invent anything that wasn't said.
    """

  public static func arguments() -> [String] {
    ["-p", "--output-format", "json", "--no-session-persistence", "--tools", "",
     "--settings", #"{"disableAllHooks":true}"#, "--strict-mcp-config", "--append-system-prompt", systemPrompt]
  }

  /// The notes prompt: the meeting, the transcript, and the JSON shape to reply with.
  public static func notes(_ record: MeetingRecord, you: String) -> String {
    """
    Meeting: \(record.title)
    When: \(record.start.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute())), \
    \(Int((record.duration() / 60).rounded())) minutes
    The user: \(you) (lines from "\(you)" are theirs)

    Transcript:
    \(trimmed(MeetingTranscript.text(record, you: you)))

    Write the notes. Reply with only this JSON object:
    {"title": "a short title if the meeting's title above is generic, else null",
     "overview": "2-4 sentences: what the meeting was about and where it landed",
     "decisions": ["each decision made"],
     "actionItems": [{"task": "what to do", "owner": "who, as named, or null", "mine": true if \(you) owns it}],
     "openQuestions": ["questions left unanswered"]}
    Use empty lists when there are none.
    """
  }

  /// A question about the meeting, live or later, with the transcript (so far) and any notes.
  public static func ask(_ question: String, record: MeetingRecord, you: String, live: Bool) -> String {
    var text = """
      \(live ? "I'm in this meeting right now" : "About this meeting"): \(record.title)
      I'm \(you).

      Transcript\(live ? " so far" : ""):
      \(trimmed(MeetingTranscript.text(record, you: you)))
      """
    if let summary = record.summary { text += "\n\nNotes:\n\(summary.overview)" }
    text += "\n\nQuestion: \(question.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
    text += live ? "Answer in a few short lines I can read at a glance during the call." : "Answer briefly."
    return text
  }

  /// The notes from Claude's reply, or nil when it holds no usable JSON object.
  public static func parse(_ reply: String) -> MeetingSummary? {
    guard let object = JournalRecap.jsonObject(in: reply),
          let overview = (object["overview"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !overview.isEmpty else { return nil }
    func strings(_ key: String) -> [String] {
      ((object[key] as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }
    let items: [MeetingSummary.ActionItem] = ((object["actionItems"] as? [Any]) ?? []).compactMap { item in
      guard let item = item as? [String: Any],
            let task = (item["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty
      else { return nil }
      let owner = (item["owner"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      return .init(task: task, owner: owner?.isEmpty == false ? owner : nil, mine: item["mine"] as? Bool ?? false)
    }
    let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return MeetingSummary(title: title?.isEmpty == false && title?.lowercased() != "null" ? title : nil,
                          overview: overview, decisions: strings("decisions"), actionItems: items,
                          openQuestions: strings("openQuestions"))
  }

  /// A long transcript keeps its first and last parts.
  static func trimmed(_ transcript: String) -> String {
    guard transcript.count > maxTranscript else { return transcript }
    let half = maxTranscript / 2
    return String(transcript.prefix(half)) + "\n[… middle of the meeting left out …]\n" + String(transcript.suffix(half))
  }

  /// The note to paste in the call's chat before recording.
  public static let notice = "Heads up: I'm taking notes of this call (transcribed on my Mac)."
}
