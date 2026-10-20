import Foundation

/// What was picked from the Tab menu where (spec "S3", "Score": the Tab menu puts what was picked before in the same
/// place first). A place is the command and its subcommands before the word being completed: `git` for `git ch⇥`,
/// `git checkout` for `git checkout ma⇥`; options and paths don't count.
public enum CompletionPicks {
  public static func context(line: String, start: Int) -> String {
    let scalars = Array(line.unicodeScalars)
    var view = String.UnicodeScalarView()
    view.append(contentsOf: scalars[0..<min(max(start, 0), scalars.count)])
    let words = String(view).split(whereSeparator: \.isWhitespace).map(String.init)
      .filter { !$0.hasPrefix("-") && !$0.contains("/") && !$0.contains("=") }
    return words.prefix(2).joined(separator: " ")
  }
}
