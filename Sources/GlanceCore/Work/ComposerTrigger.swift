import Foundation

/// What the caret is in the middle of in the Glance composer: a slash command at the start, or an @file mention.
public enum ComposerTrigger: Equatable, Sendable {
  case slash(query: String)
  case mention(query: String, start: Int)

  public static func at(_ text: String, caret: Int) -> ComposerTrigger? {
    let utf16 = Array(text.utf16)
    guard caret <= utf16.count else { return nil }
    let before = String(decoding: utf16[0..<caret], as: UTF16.self)
    if before.hasPrefix("/"), !before.contains(where: \.isWhitespace) { return .slash(query: String(before.dropFirst())) }
    var i = caret
    while i > 0, let s = UnicodeScalar(utf16[i - 1]), !CharacterSet.whitespacesAndNewlines.contains(s) { i -= 1 }
    guard i < caret, utf16[i] == 0x40 /* @ */ else { return nil }
    return .mention(query: String(decoding: utf16[(i + 1)..<caret], as: UTF16.self), start: i)
  }

  public static func replaceMention(in text: String, start: Int, caret: Int, with path: String) -> (text: String, caret: Int) {
    let utf16 = Array(text.utf16)
    let insert = "@" + path + " "
    let out = String(decoding: utf16[0..<start], as: UTF16.self) + insert + String(decoding: utf16[caret...], as: UTF16.self)
    return (out, start + insert.utf16.count)
  }
}

public enum FileMention {
  public static func rank(_ query: String, in paths: [String], limit: Int = 20) -> [String] {
    let q = query.lowercased()
    func score(_ path: String) -> Int? {
      let p = path.lowercased(), base = (p as NSString).lastPathComponent
      if base.hasPrefix(q) { return 0 }
      if base.contains(q) { return 1 }
      if p.contains(q) { return 2 }
      return nil
    }
    return paths.compactMap { p in score(p).map { (p, $0) } }
      .sorted { ($0.1, $0.0.count, $0.0) < ($1.1, $1.0.count, $1.0) }
      .prefix(limit).map(\.0)
  }
}
