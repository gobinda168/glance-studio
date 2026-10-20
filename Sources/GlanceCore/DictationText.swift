/// Prepares dictated text for typing into a terminal prompt.
public enum DictationText {
  /// Collapses every whitespace run, newlines included, to one space: a newline would press Return in
  /// Claude Code's prompt and send it.
  public static func finalize(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  /// Splits into pieces of at most `maxUTF16` UTF-16 units for `CGEvent` unicode strings, never inside a
  /// Character (emoji with modifiers, flags, combining marks stay whole even if one exceeds the limit).
  public static func chunks(_ text: String, maxUTF16: Int = 20) -> [String] {
    var chunks: [String] = []
    var current = ""
    for character in text {
      if !current.isEmpty, current.utf16.count + character.utf16.count > maxUTF16 {
        chunks.append(current)
        current = ""
      }
      current.append(character)
    }
    if !current.isEmpty { chunks.append(current) }
    return chunks
  }
}
