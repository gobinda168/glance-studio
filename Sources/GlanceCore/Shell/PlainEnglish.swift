import Foundation

/// Telling a sentence from a command (spec "S5"): a line typed at the prompt that reads like a request in plain
/// English ("create a directory", "show me the biggest files") is turned into a command for the user to review;
/// everything else runs as typed.
public enum PlainEnglish {
  /// Verbs that start a request on their own; with one of these two words are enough.
  static let verbs: Set<String> = [
    "add", "back", "build", "change", "check", "clean", "clear", "clone", "close", "compress", "copy", "count", "create",
    "delete", "download", "extract", "find", "go", "how", "install", "kill", "list", "make", "move", "open", "push",
    "remove", "rename", "restart", "run", "search", "show", "start", "stop", "undo", "uninstall", "update", "upload",
    "what", "where", "which", "who", "why",
  ]

  /// Whether `line` is a request in plain English: its first word is not a command the shell has (`isKnown`), every
  /// word is made of letters (an apostrophe, comma, full stop or question mark may end or join them), and it has three
  /// words or more, or two when the first is a verb. Flags, paths, quotes, variables, pipes and numbers-with-symbols
  /// make it a command.
  public static func isRequest(_ line: String, isKnown: (String) -> Bool) -> Bool {
    let text = line.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty, !text.hasPrefix("#"), !text.contains("\n") else { return false }
    let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard words.count >= 2, let first = words.first else { return false }
    guard words.allSatisfy(isWord) else { return false }
    // A known command is a command, whatever follows ("find the files" is not: `find` is, so it runs as typed).
    if isKnown(first) || isKnown(first.lowercased()) { return false }
    return words.count >= 3 || verbs.contains(first.lowercased())
  }

  /// Letters, with an apostrophe or a hyphen inside and ordinary punctuation at the end; digits only inside a word
  /// that has letters ("python3" is a command, "3" alone is not a word of a sentence).
  static func isWord(_ word: String) -> Bool {
    var core = Substring(word)
    while let last = core.last, ",.?!".contains(last) { core = core.dropLast() }
    guard !core.isEmpty, core.contains(where: \.isLetter) else { return false }
    return core.allSatisfy { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }
      && core.first?.isLetter == true && !core.hasSuffix("-")
  }
}
