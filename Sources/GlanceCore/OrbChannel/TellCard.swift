import CoreGraphics
import Foundation

/// How tall Glance's card is for a `tell` (spec "Telling the user"): auto fits the content between a short card and
/// full height; short caps it; full opens it full. Short cards fold back into the orb after they've been read.
public enum TellCard {
  public enum Size: String, Codable, CaseIterable, Sendable { case auto, short, full }

  public static let minHeight: CGFloat = 120
  public static let shortLimit: CGFloat = 260
  public static let fullHeight: CGFloat = 600
  public static let foldDelay: TimeInterval = 10

  public static func height(content: CGFloat, size: Size) -> CGFloat {
    switch size {
    case .auto: min(max(content, minHeight), fullHeight)
    case .short: min(max(content, minHeight), shortLimit)
    case .full: fullHeight
    }
  }

  public static func folds(height: CGFloat) -> Bool { height <= shortLimit }

  /// The title of the card at the top when Studio isn't in front: the markdown's first line of text (code blocks and
  /// table rules skipped) without its marks, at most 80 characters.
  public static func headline(_ markdown: String) -> String {
    var fenced = false
    var line: Substring?
    for candidate in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = candidate.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenced.toggle(); continue }
      guard !fenced, !trimmed.isEmpty, trimmed.contains(where: { !"|-: ".contains($0) }) else { continue }
      line = Substring(trimmed)
      break
    }
    guard var text = line.map(String.init) else { return fallback }
    // Block marks (repeatedly: "> 1. "), then links and images as their text, then inline marks.
    let blockMark = /^(#{1,6}|>|[-*+]|\d+[.)])\s+/
    while let match = text.firstMatch(of: blockMark) { text.removeSubrange(match.range) }
    text = text.replacing(/!?\[([^\]]*)\]\([^)]*\)/) { String($0.output.1) }
    text = text.replacing(/\*\*|__|~~|`|\*/, with: "")
    let chars = Array(text)
    let word = { (index: Int) in chars.indices.contains(index) && (chars[index].isLetter || chars[index].isNumber) }
    text = String(chars.indices.filter { chars[$0] != "_" || (word($0 - 1) && word($0 + 1)) }.map { chars[$0] })
    text = text.replacing("|", with: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !text.isEmpty else { return fallback }
    guard text.count > 80 else { return text }
    return text.prefix(79).trimmingCharacters(in: .whitespaces) + "…"
  }

  static let fallback = "Glance has something to tell you"
}
