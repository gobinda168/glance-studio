import Foundation

/// One of zsh's completion candidates, as the plugin collected it from `compadd` (spec "S1: the Tab menu").
public struct CompletionCandidate: Equatable, Sendable, Identifiable {
  public enum Kind: String, Sendable {
    case command, option, folder, file, branch, host, user, process, variable, value
  }

  /// The shell's number for it (1-based), what `accept` names.
  public let index: Int
  /// zsh's name for its group ("main porcelain command", "local branch"), "" when it gave none.
  public let group: String
  /// zsh's tag ("options", "globbed-files", "heads-local").
  public let tag: String
  /// The match as zsh inserts it, quoted (`my\ file.txt`).
  public let word: String
  /// What the menu shows: zsh's display string before its ` -- `, else the word without its backslash quoting.
  public let name: String
  /// The description after the ` -- `.
  public let detail: String
  public let isFile: Bool
  public let isDirectory: Bool
  /// zsh keeps this group in its own order (`compadd -V`); other groups are sorted.
  public let isOrdered: Bool
  /// Where, in the line, the text this candidate is matched against starts.
  public let start: Int
  /// zsh's hidden prefix: the folder already typed in front of a path's last part.
  public let hidden: String
  public let kind: Kind

  public var id: Int { index }

  /// From a `cand` row's fields after the request id: index, group, tag, word, display, flags (`f` file, `d`
  /// directory, `o` ordered), start, hidden prefix.
  public init?(fields: ArraySlice<String>) {
    let f = Array(fields)
    guard f.count >= 7, let index = Int(f[0]), let start = Int(f[6]) else { return nil }
    self.index = index
    group = f[1]
    tag = f[2]
    word = f[3]
    let flags = f[5]
    isFile = flags.contains("f")
    isDirectory = flags.contains("d")
    isOrdered = flags.contains("o")
    self.start = start
    hidden = f.count > 7 ? f[7] : ""
    let display = f[4]
    if let separator = display.range(of: " -- ") {
      name = String(display[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
      detail = String(display[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
    } else if display.isEmpty {
      name = Self.unquoted(word)
      detail = ""
    } else {
      name = display.trimmingCharacters(in: .whitespaces)
      detail = ""
    }
    kind = Self.kind(tag: tag, isFile: isFile, isDirectory: isDirectory)
  }

  /// The word without zsh's backslash quoting (`my\ file.txt` → `my file.txt`).
  public static func unquoted(_ word: String) -> String {
    guard word.contains("\\") else { return word }
    var out = ""
    var escaping = false
    for character in word {
      if escaping { out.append(character); escaping = false } else if character == "\\" { escaping = true } else {
        out.append(character)
      }
    }
    return out
  }

  static func kind(tag: String, isFile: Bool, isDirectory: Bool) -> Kind {
    if isDirectory || ["directories", "local-directories", "named-directories", "path-directories"].contains(tag) {
      return .folder
    }
    if isFile { return .file }
    switch tag {
    case "options": return .option
    case "builtins", "functions", "aliases", "reserved-words", "suffix-aliases": return .command
    case "hosts": return .host
    case "users": return .user
    case "processes", "process-names", "jobs": return .process
    case "parameters": return .variable
    default: break
    }
    if tag.contains("command") { return .command }
    if ["branch", "head", "ref", "tag", "commit", "remote"].contains(where: tag.contains) { return .branch }
    return .value
  }
}
