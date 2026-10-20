import Foundation

/// Claude Code transcripts (`~/.claude/projects/*/*.jsonl`) read for Journal (spec 2026-10-09-journal-design.md,
/// "Capture"). Each session's messages in a time range become one event per session per day: its prompts, the files
/// Claude edited, and its active time (messages at most `gap` apart joined). Subagent (sidechain) and meta lines are
/// skipped, and so are sessions in temp folders, where Glance's own one-shot runs happen.
public enum JournalTranscripts {
  public static let gap: TimeInterval = 15 * 60
  static let promptLimit = 300
  static let promptCount = 40
  static let fileCount = 50
  static let titleLimit = 80
  static let editTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

  /// A temp folder: `temporary` (the app's `NSTemporaryDirectory()`), `/tmp` or `/var/folders`.
  public static func isScratch(_ folder: String, temporary: String = NSTemporaryDirectory()) -> Bool {
    let path = folder.hasSuffix("/") ? folder : folder + "/"
    return [temporary, "/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"].contains { prefix in
      !prefix.isEmpty && path.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/")
    }
  }

  private struct Session {
    var sessionID: String
    var cwd: String
    var points: [Date] = []
    var branch: String?
    var prompts: [String] = []
    var files: [String] = []
  }

  /// The sessions in `lines` (one transcript) with messages inside `range`, one event per session per day. `root`
  /// maps a session's folder to its project (its git root).
  public static func events(lines: some Sequence<String>, in range: DateInterval, calendar: Calendar,
                            root: (String) -> String = { $0 },
                            temporary: String = NSTemporaryDirectory()) -> [JournalEvent] {
    var sessions: [String: Session] = [:]
    var order: [String] = []
    var titles: [String: String] = [:]
    for line in lines {
      guard line.contains("\"sessionId\""),
            let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            let sessionID = entry["sessionId"] as? String else { continue }
      let type = entry["type"] as? String
      if type == "ai-title" {
        if let title = entry["aiTitle"] as? String { titles[sessionID] = title }
        continue
      }
      guard type == "user" || type == "assistant",
            entry["isSidechain"] as? Bool != true, entry["isMeta"] as? Bool != true,
            let time = (entry["timestamp"] as? String).flatMap(JournalTime.parse),
            time >= range.start, time < range.end,
            let cwd = entry["cwd"] as? String, !isScratch(cwd, temporary: temporary),
            let message = entry["message"] as? [String: Any] else { continue }
      let key = sessionID + "|" + JournalDay(time, calendar: calendar).key
      if sessions[key] == nil { order.append(key) }
      var session = sessions[key] ?? Session(sessionID: sessionID, cwd: cwd)
      session.points.append(time)
      if session.branch == nil, let branch = entry["gitBranch"] as? String, !branch.isEmpty, branch != "HEAD" {
        session.branch = branch
      }
      if type == "user" {
        if Transcript.isPrompt(message["content"]), let prompt = promptText(message["content"]) {
          session.prompts.append(prompt)
        }
      } else {
        for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_use" {
          guard let name = block["name"] as? String, editTools.contains(name),
                let input = block["input"] as? [String: Any],
                let path = (input["file_path"] ?? input["notebook_path"]) as? String else { continue }
          session.files.append(relative(path, to: session.cwd))
        }
      }
      sessions[key] = session
    }
    return order.compactMap { key in
      guard let session = sessions[key], let first = session.points.min(), let last = session.points.max() else {
        return nil
      }
      let day = JournalDay(first, calendar: calendar)
      let spans = JournalSpans.join(session.points, gap: gap)
      var seen = Set<String>()
      let files = session.files.filter { seen.insert($0).inserted }
      let title = (titles[session.sessionID] ?? session.prompts.first).map { JournalText.clean($0, limit: titleLimit) }
      return JournalEvent(
        source: .claude, externalID: "\(session.sessionID):\(day.key)", day: day, start: first, end: last,
        project: root(session.cwd), title: title ?? "Claude Code session",
        detail: JournalDetail(prompts: Array(session.prompts.prefix(promptCount)), files: Array(files.prefix(fileCount)),
                              turns: session.prompts.count, activeMinutes: JournalSpans.minutes(spans), spans: spans,
                              branch: session.branch))
    }
  }

  /// What the user typed, cleaned; nil for Claude Code's own wrappers (slash commands, local command output).
  static func promptText(_ content: Any?) -> String? {
    let text: String
    if let string = content as? String {
      text = string
    } else if let blocks = content as? [[String: Any]] {
      text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
    } else {
      return nil
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("<"), !trimmed.hasPrefix("Caveat:") else { return nil }
    return JournalText.clean(trimmed, limit: promptLimit)
  }

  static func relative(_ path: String, to folder: String) -> String {
    let base = folder.hasSuffix("/") ? folder : folder + "/"
    return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
  }
}
