import Foundation

/// What a Claude Code session was about, for the session signal: the user's prompts (Claude Code's own wrappers left
/// out) and the git branch it ran on.
public enum TicketTranscript {
  public static func scan(_ lines: [String]) -> (prompts: [String], branch: String?) {
    var prompts: [String] = []
    var branch: String?
    for line in lines {
      guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
      if branch == nil, let name = entry["gitBranch"] as? String, !name.isEmpty, name != "HEAD" { branch = name }
      guard entry["type"] as? String == "user",
            let text = JournalTranscripts.promptText((entry["message"] as? [String: Any])?["content"]) else { continue }
      prompts.append(text)
    }
    return (prompts, branch)
  }
}
