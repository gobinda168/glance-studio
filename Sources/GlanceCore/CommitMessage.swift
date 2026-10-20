import Foundation

/// The Changes panel's ✦ button: Claude drafts a commit message from the staged diff, in the style of the project's
/// recent commits. Runs only when asked.
public enum CommitMessage {
  /// What the draft run streams to the page.
  public enum DraftEvent: Equatable, Sendable {
    case text(String)
    case done(String)
    case failed(String)
  }

  static let rules = """
    Write the git commit message for the changes below. Answer with the message only: a subject line under 72 \
    characters, in the imperative mood, in the style of the recent commits (keep their "type(scope): " prefix when \
    they use one); then, only when the change needs explaining, a blank line and a short body wrapped at 72 \
    characters. No code fences, no quotes, no greetings and nothing about yourself.
    """

  /// The recent subjects (newest first) and the diff, cut at `limit` characters (the prompt says by how much).
  /// `staged`: the diff is what is staged; otherwise it is every uncommitted change.
  public static func prompt(diff: String, recent: [String], staged: Bool, limit: Int = 60_000) -> String {
    var lines = [rules, "", "Recent commits (newest first):"]
    lines += recent.isEmpty ? ["(none)"] : recent.map { "- \($0)" }
    lines += ["", staged ? "The staged diff:" : "Nothing is staged; every uncommitted change:"]
    lines.append(diff.count > limit ? String(diff.prefix(limit)) : diff)
    if diff.count > limit { lines.append("[The diff goes on for \(diff.count - limit) more characters.]") }
    return lines.joined(separator: "\n")
  }

  /// Claude's answer as a message: code fences and blank edges dropped.
  public static func clean(_ answer: String) -> String {
    var lines = answer.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      .components(separatedBy: "\n")
    if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
    if lines.last?.hasPrefix("```") == true { lines.removeLast() }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
