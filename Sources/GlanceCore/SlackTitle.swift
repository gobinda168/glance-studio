import Foundation

/// What Slack's page title says (spec 2026-10-09-chats-slack-design.md, "Unread counts"): how many mentions, whether
/// anything is unread, and the workspace's name. A title it doesn't understand has nothing unread and no name.
public struct SlackTitle: Equatable, Sendable {
  public let mentions: Int
  public let unread: Bool
  public let workspace: String?

  public init(mentions: Int, unread: Bool, workspace: String?) {
    self.mentions = mentions
    self.unread = unread
    self.workspace = workspace
  }

  public init(_ title: String) {
    var rest = Substring(title.trimmingCharacters(in: .whitespaces))
    var mentions = 0
    var unread = false
    // Leading markers, in any order: "(3) " a mention count, "! " a mention, "* " or "• " unread.
    while true {
      if rest.hasPrefix("("), let close = rest.firstIndex(of: ")"),
         let count = Int(rest[rest.index(after: rest.startIndex)..<close]) {
        mentions = max(mentions, count)
        rest = rest[rest.index(after: close)...].drop { $0 == " " }
      } else if rest.hasPrefix("! ") {
        mentions = max(mentions, 1)
        rest = rest.dropFirst(2)
      } else if rest.hasPrefix("* ") || rest.hasPrefix("• ") {
        unread = true
        rest = rest.dropFirst(2)
      } else {
        break
      }
    }
    self.mentions = mentions
    self.unread = unread || mentions > 0
    self.workspace = Self.workspace(in: String(rest))
  }

  /// `<page> - <workspace> - Slack`: what sits between the first " - " and the final " - Slack".
  /// `Slack | <page> | <workspace>`: what follows the second " | ".
  private static func workspace(in text: String) -> String? {
    if text.hasSuffix(" - Slack") {
      let body = text.dropLast(" - Slack".count)
      guard let first = body.range(of: " - ") else { return nil }
      let name = body[first.upperBound...].trimmingCharacters(in: .whitespaces)
      return name.isEmpty ? nil : name
    }
    if text.hasPrefix("Slack | ") {
      let body = text.dropFirst("Slack | ".count)
      guard let page = body.range(of: " | ") else { return nil }
      let name = body[page.upperBound...].trimmingCharacters(in: .whitespaces)
      return name.isEmpty ? nil : name
    }
    return nil
  }
}
