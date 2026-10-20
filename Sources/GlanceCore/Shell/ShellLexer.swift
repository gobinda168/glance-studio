import Foundation

/// A small zsh lexer for the line being typed (spec "S4: error detection"): its words with their positions (Unicode
/// scalars, zsh's units), which of them are in command position, and an unclosed quote, `$(` or backtick. It isn't
/// zsh's parser: it knows quotes, escapes, `$( )` and backticks (nested), the operators that start a new command
/// (`|`, `||`, `&&`, `;`, `&`, `(`, newline), redirections, `NAME=value`, reserved words, and precommands (`sudo`,
/// `env`, `nohup`, `time`, …) with their options.
public enum ShellLexer {
  public struct Word: Equatable, Sendable {
    /// As typed, quotes included.
    public let text: String
    public let start: Int
    public let end: Int
    public let commandPosition: Bool
  }

  public struct Result: Equatable, Sendable {
    public let words: [Word]
    /// Where an unclosed quote, `$(` or backtick opens.
    public let unclosed: Int?
  }

  /// Words that keep the next word in command position.
  static let leading: Set<String> = ["if", "then", "else", "elif", "while", "until", "do", "!", "{", "time", "coproc",
                                     "nocorrect", "noglob", "exec", "command", "builtin", "nohup", "sudo", "doas",
                                     "env", "nice", "caffeinate"]
  /// Precommands whose options are skipped, and the options that take a value.
  static let optionsTakingValue: [String: Set<String>] = [
    "sudo": ["-u", "-g", "-h", "-p", "-C", "-U", "-r", "-t", "-D", "-T"], "doas": ["-u", "-C"],
    "env": ["-u", "-S", "-C", "-P"], "nice": ["-n"], "caffeinate": ["-t", "-w"],
    "exec": ["-a"], "command": [], "builtin": [], "nohup": [],
  ]
  /// zsh's reserved words: never unknown commands.
  public static let reserved: Set<String> = ["if", "then", "else", "elif", "fi", "case", "esac", "for", "select",
                                             "while", "until", "do", "done", "function", "time", "repeat", "coproc",
                                             "nocorrect", "noglob", "foreach", "end", "{", "}", "[[", "]]", "!", "in"]

  public static func lex(_ line: String) -> Result {
    let s = Array(line.unicodeScalars)
    var words: [Word] = []
    var unclosed: Int?
    var commandPosition = true
    var redirectTarget = false
    /// The precommand whose options are being skipped, and whether the next word is an option's value.
    var precommand: String?
    var skipValue = false
    var i = 0
    while i < s.count {
      let c = s[i]
      if c == " " || c == "\t" {
        i += 1
        continue
      }
      // Operators that start a new command.
      if c == "\n" || c == ";" || c == "|" || c == "(" || (c == "&" && !(i + 1 < s.count && s[i + 1] == ">")) {
        i += 1
        if i < s.count && (s[i] == c || (c == "|" && s[i] == "&")) { i += 1 } // && || ;; |&
        commandPosition = true
        redirectTarget = false
        precommand = nil
        skipValue = false
        continue
      }
      if c == ")" {
        i += 1
        commandPosition = false
        continue
      }
      // Redirections: the next word is a file.
      if c == "<" || c == ">" || (c == "&" && i + 1 < s.count && s[i + 1] == ">")
          || (c.properties.numericType != nil && i + 1 < s.count && (s[i + 1] == ">" || s[i + 1] == "<")
              && (i == 0 || s[i - 1] == " ")) {
        while i < s.count && "<>&|0123456789".unicodeScalars.contains(s[i]) { i += 1 }
        redirectTarget = true
        continue
      }
      // A word.
      let start = i
      let (end, open) = scanWord(s, from: i)
      if let open { unclosed = open }
      let text = String(String.UnicodeScalarView(s[start..<end]))
      let bare = unquoted(text)
      var isCommand = commandPosition && !redirectTarget
      if redirectTarget {
        redirectTarget = false
      } else if commandPosition {
        if skipValue {
          // A precommand option's value (`sudo -u admin`).
          skipValue = false
          isCommand = false
        } else if let pre = precommand, bare.hasPrefix("-") {
          isCommand = false
          if optionsTakingValue[pre]?.contains(bare) == true { skipValue = true }
        } else if isAssignment(text) {
          isCommand = false
        } else if leading.contains(bare) {
          precommand = optionsTakingValue[bare] != nil ? bare : nil
        } else {
          // The command itself: what follows are its arguments (`for x in …` and `case x in` too).
          commandPosition = false
          precommand = nil
        }
      }
      words.append(Word(text: text, start: start, end: end, commandPosition: isCommand))
      i = max(end, i + 1)
    }
    return Result(words: words, unclosed: unclosed)
  }

  /// Where the word starting at `start` ends, and where an unclosed quote/substitution in it opens (nil when closed).
  static func scanWord(_ s: [Unicode.Scalar], from start: Int) -> (end: Int, unclosed: Int?) {
    var i = start
    while i < s.count {
      let c = s[i]
      if c == " " || c == "\t" || c == "\n" || c == ";" || c == "|" || c == "&" || c == "<" || c == ">" || c == ")"
          || (c == "(" && i > start) {
        return (i, nil)
      }
      if c == "\\" {
        i += 2
        continue
      }
      if c == "'" || c == "\"" || c == "`" {
        guard let close = scanQuote(s, from: i) else { return (s.count, i) }
        i = close
        continue
      }
      if c == "$" && i + 1 < s.count && s[i + 1] == "(" {
        guard let close = scanSubstitution(s, from: i + 2) else { return (s.count, i) }
        i = close
        continue
      }
      i += 1
    }
    return (min(i, s.count), nil)
  }

  /// After the closing quote of the quote opening at `start`, or nil when it never closes.
  static func scanQuote(_ s: [Unicode.Scalar], from start: Int) -> Int? {
    let quote = s[start]
    var i = start + 1
    while i < s.count {
      let c = s[i]
      if quote != "'" && c == "\\" {
        i += 2
        continue
      }
      if c == quote { return i + 1 }
      if quote == "\"" && c == "$" && i + 1 < s.count && s[i + 1] == "(" {
        guard let close = scanSubstitution(s, from: i + 2) else { return nil }
        i = close
        continue
      }
      i += 1
    }
    return nil
  }

  /// After the `)` closing a `$(` whose content starts at `start`, or nil.
  static func scanSubstitution(_ s: [Unicode.Scalar], from start: Int) -> Int? {
    var depth = 1
    var i = start
    while i < s.count {
      let c = s[i]
      if c == "\\" {
        i += 2
        continue
      }
      if c == "'" || c == "\"" || c == "`" {
        guard let close = scanQuote(s, from: i) else { return nil }
        i = close
        continue
      }
      if c == "(" { depth += 1 }
      if c == ")" {
        depth -= 1
        if depth == 0 { return i + 1 }
      }
      i += 1
    }
    return nil
  }

  /// `NAME=value` (an assignment before a command).
  static func isAssignment(_ word: String) -> Bool {
    guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
    let name = word[..<equals]
    guard let first = name.first, first == "_" || first.isLetter else { return false }
    return name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
  }

  /// The word without its quoting: backslashes and quote characters dropped.
  public static func unquoted(_ word: String) -> String {
    var out = ""
    var escaped = false
    for character in word {
      if escaped {
        out.append(character)
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else if character != "'" && character != "\"" {
        out.append(character)
      }
    }
    return out
  }
}

/// The error marks on the line being typed (spec "S4", "Marks while typing"): command words that aren't known (once
/// the cursor has left them) and an unclosed quote, `$(` or backtick.
public enum LineMarks {
  public static func marks(line: String, cursor: Int, isKnown: (String) -> Bool) -> [ShellMark] {
    let lexed = ShellLexer.lex(line)
    var marks: [ShellMark] = []
    for word in lexed.words where word.commandPosition && !(word.start...word.end).contains(cursor) {
      let name = ShellLexer.unquoted(word.text)
      guard shouldCheck(name, raw: word.text), !ShellLexer.reserved.contains(name), !isKnown(name) else { continue }
      marks.append(ShellMark(start: word.start, end: word.end, kind: "unknown"))
    }
    if let open = lexed.unclosed { marks.append(ShellMark(start: open, end: open + 1, kind: "quote")) }
    return marks
  }

  /// Whether every command `line` runs is known, judged as the marks judge a word: history keeps a mistyped command
  /// (`pnpf dev`) out of the suggestions this way.
  public static func runs(_ line: String, isKnown: (String) -> Bool) -> Bool {
    ShellLexer.lex(line).words.allSatisfy { word in
      guard word.commandPosition else { return true }
      let name = ShellLexer.unquoted(word.text)
      return !shouldCheck(name, raw: word.text) || ShellLexer.reserved.contains(name) || isKnown(name)
    }
  }

  /// Words a name check can judge: no expansions, globs, history references or options.
  static func shouldCheck(_ name: String, raw: String) -> Bool {
    !name.isEmpty && !raw.contains("$") && !raw.contains("`") && !name.hasPrefix("!") && !name.hasPrefix("-")
      && !name.contains("=") && !name.contains(where: { "*?[]{}()".contains($0) })
  }
}
