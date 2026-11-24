import Foundation

/// What a session is called in notes and in the Worktrees view: its summary's title (Glance's summaries), else its
/// first prompt, else its id's first eight characters.
public enum SessionName {
  public static var summaries: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Glance/Summaries")
  }

  public static func of(_ id: String, task: String?, summaries: URL = SessionName.summaries) -> String {
    if let data = FileManager.default.contents(atPath: summaries.appendingPathComponent(id + ".json").path),
       let title = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["title"] as? String,
       !title.isEmpty {
      return title
    }
    return fallback(id, task: task)
  }

  /// The name without the summary: what the board shows until it has read the summary off the main thread.
  public static func fallback(_ id: String, task: String?) -> String {
    // A session started from a recap has its context ahead of what was typed: the name is the typed part.
    if let task = task.map(RecapText.typedText)?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty {
      return task.count > 60 ? String(task.prefix(57)) + "…" : task
    }
    return "session " + id.prefix(8)
  }
}
