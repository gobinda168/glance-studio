import Foundation

/// Which cached tickets a piece of text names (spec "Signals": only keys Glance has, so "UTF-8" never matches). Jira
/// and Linear keys match in any case with no letter or digit before and no digit after; a GitHub issue ("owner/name#88")
/// matches "#88" only in text from its own repository.
public enum TicketKeys {
  public static func mentioned(in text: String, tickets: [Ticket], repository: String?) -> [Ticket] {
    guard !text.isEmpty else { return [] }
    let upper = text.uppercased()
    return tickets.filter { ticket in
      if let owner = ticket.repository, let hash = ticket.key.lastIndex(of: "#") {
        guard let repository, repository.caseInsensitiveCompare(owner) == .orderedSame else { return false }
        return occurs("#" + ticket.key[ticket.key.index(after: hash)...], in: text)
      }
      return occurs(ticket.key.uppercased(), in: upper)
    }
  }

  static func occurs(_ needle: String, in haystack: String) -> Bool {
    var start = haystack.startIndex
    while start < haystack.endIndex, let range = haystack.range(of: needle, range: start..<haystack.endIndex) {
      let before = range.lowerBound == haystack.startIndex ? nil : haystack[haystack.index(before: range.lowerBound)]
      let after = range.upperBound == haystack.endIndex ? nil : haystack[range.upperBound]
      let joinedBefore = (before?.isLetter ?? false) || (before?.isNumber ?? false)
      let joinedAfter = after?.isNumber ?? false
      if !joinedBefore && !joinedAfter { return true }
      start = haystack.index(after: range.lowerBound)
    }
    return false
  }
}
