import Foundation


/// Glance Humanize (spec 2026-10-11-humanize-summaries-design.md, "Glance Humanize"): the style's text, and how
/// Studio's headless chats (Razor Chat, the orb assistant, Inline Ask) get it. Interactive terminals get the same file
/// as a plugin output style (`HumanizePlugin`).
public enum HumanizeStyle {
  /// The style file without its front matter: what goes after a chat's system prompt.
  public static func body(of markdown: String) -> String {
    let trimmed = { (text: Substring) in text.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard markdown.hasPrefix("---\n") else { return trimmed(markdown[...]) }
    let rest = markdown.dropFirst(4)
    guard let end = rest.range(of: "\n---\n") else { return trimmed(markdown[...]) }
    return trimmed(rest[end.upperBound...])
  }

  /// `arguments` with Humanize when `style` asks for it. Claude Code takes one appended system prompt, so the text
  /// joins an existing `--append-system-prompt` value (Inline Ask's rules) or comes as a new one. Claude Default (or no
  /// text) returns `arguments` unchanged.
  public static func apply(_ style: ResponseStyle, body: String, to arguments: [String]) -> [String] {
    guard style == .humanize, !body.isEmpty else { return arguments }
    var result = arguments
    if let flag = result.firstIndex(of: "--append-system-prompt"), flag + 1 < result.count {
      result[flag + 1] += "\n\n" + body
    } else {
      result += ["--append-system-prompt", body]
    }
    return result
  }
}
