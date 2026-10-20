import Foundation

/// Colours for one line of code at a time, for the PR diffs: keywords, strings, comments, numbers, types, calls.
/// - It reads a line on its own, so a block comment or a multi-line string is coloured only on the lines that open it.
/// - An unknown file type stays plain.
public enum SyntaxHighlight {
  public enum Kind: Equatable, Sendable {
    case keyword, string, comment, number, type, function, attribute, property
  }

  /// A piece of the line: its text and what it is (nil for plain text).
  public struct Segment: Equatable, Sendable {
    public let text: String
    public let kind: Kind?

    public init(_ text: String, _ kind: Kind? = nil) {
      self.text = text
      self.kind = kind
    }
  }

  public enum Language: CaseIterable, Sendable {
    case python, javascript, swift, go, rust, cLike, shell, ruby, json, yaml, css, html, markdown, sql

    private static let byExtension: [String: Language] = [
      "py": .python, "pyi": .python,
      "js": .javascript, "jsx": .javascript, "mjs": .javascript, "cjs": .javascript,
      "ts": .javascript, "tsx": .javascript, "mts": .javascript, "cts": .javascript,
      "swift": .swift, "go": .go, "rs": .rust,
      "c": .cLike, "h": .cLike, "cc": .cLike, "cpp": .cLike, "hpp": .cLike, "m": .cLike, "mm": .cLike,
      "java": .cLike, "kt": .cLike, "kts": .cLike, "cs": .cLike, "scala": .cLike, "dart": .cLike, "zig": .cLike,
      "sh": .shell, "bash": .shell, "zsh": .shell, "fish": .shell,
      "rb": .ruby, "json": .json, "jsonc": .json, "yaml": .yaml, "yml": .yaml, "toml": .yaml,
      "css": .css, "scss": .css, "less": .css,
      "html": .html, "htm": .html, "xml": .html, "svg": .html, "vue": .html,
      "md": .markdown, "markdown": .markdown, "sql": .sql,
    ]

    private static let byName: [String: Language] = [
      "Dockerfile": .shell, "Makefile": .shell, "Gemfile": .ruby, "Rakefile": .ruby, "Podfile": .ruby,
      ".zshrc": .shell, ".bashrc": .shell,
    ]

    /// The language of a file by its name, or nil when it isn't one these colours know.
    public init?(path: String) {
      let name = path.split(separator: "/").last.map(String.init) ?? path
      if let language = Self.byName[name] {
        self = language
        return
      }
      guard let dot = name.lastIndex(of: "."), dot != name.startIndex,
            let language = Self.byExtension[name[name.index(after: dot)...].lowercased()] else { return nil }
      self = language
    }
  }

  public static func segments(_ line: String, language: Language) -> [Segment] {
    guard let grammar = Grammar.all[language] else { return [Segment(line)] }
    let text = line as NSString
    var segments: [Segment] = []
    var cursor = 0

    func add(_ range: NSRange, _ kind: Kind?) {
      guard range.length > 0 else { return }
      let piece = text.substring(with: range)
      if let last = segments.last, last.kind == kind {
        segments[segments.count - 1] = Segment(last.text + piece, kind)
      } else {
        segments.append(Segment(piece, kind))
      }
    }

    for match in grammar.regex.matches(in: line, range: NSRange(location: 0, length: text.length)) {
      guard match.range.length > 0 else { continue }
      add(NSRange(location: cursor, length: match.range.location - cursor), nil)
      add(match.range, grammar.kind(of: match, in: text))
      cursor = match.range.location + match.range.length
    }
    add(NSRange(location: cursor, length: text.length - cursor), nil)
    return segments
  }

  /// One language's rules, as one regular expression of named alternatives: the earliest match wins, so a keyword
  /// inside a string or a comment stays part of it.
  private struct Grammar: @unchecked Sendable {
    let regex: NSRegularExpression
    let keywords: Set<String>
    /// Capitalised words are types, and ALL_CAPS ones constants.
    let capitals: Bool
    /// `name!(` is a call (Rust's macros).
    let bangCalls: Bool
    /// The named groups in `regex`: asking a match for one it lacks raises.
    let groups: [(String, Kind)]

    func kind(of match: NSTextCheckingResult, in text: NSString) -> Kind? {
      for (name, kind) in groups where match.range(withName: name).location != NSNotFound {
        return kind
      }
      guard match.range(withName: "word").location != NSNotFound else { return nil }
      let word = text.substring(with: match.range)
      if keywords.contains(word) { return .keyword }
      var after = match.range.location + match.range.length
      while after < text.length, text.character(at: after) == 0x20 { after += 1 }
      if after < text.length {
        let next = text.character(at: after)
        if next == 0x28 /* ( */ || (bangCalls && next == 0x21 /* ! */) { return .function }
      }
      guard capitals, let first = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first) else {
        return nil
      }
      let allCaps = word.count > 1 && word.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "_" }
      return allCaps ? .number : .type
    }

    static let all = Dictionary(uniqueKeysWithValues: Language.allCases.map { ($0, make($0)) })

    // Pieces of the patterns.
    private static let double = #""(?:\\.|[^"\\])*"?"#
    private static let single = #"'(?:\\.|[^'\\])*'?"#
    private static let backtick = #"`(?:\\.|[^`\\])*`?"#
    private static let slashComment = #"//.*|/\*.*?(?:\*/|$)|^\s*\*(?:\s.*|/.*)?$"#
    private static let hashComment = #"(?<![^\s])#.*"#
    private static let number = #"\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?)\b"#
    private static let word = #"[A-Za-z_$][\w$]*"#

    private static func make(_ language: Language) -> Grammar {
      var comment: String?, string: String?, attribute: String?, property: String?, tag: String?
      var keywords = ""
      var capitals = true
      var bangCalls = false
      var word = Self.word

      switch language {
      case .python:
        comment = Self.hashComment
        string = #"(?:\b[rRbBfFuU]{1,2})?(?:""".*?(?:"""|$)|'''.*?(?:'''|$)|"# + Self.double + "|" + Self.single + ")"
        attribute = #"@[\w.]+"#
        keywords = """
          False None True and as assert async await break class continue def del elif else except finally for from \
          global if import in is lambda nonlocal not or pass raise return try while with yield self cls match case
          """
      case .javascript:
        comment = Self.slashComment
        string = Self.double + "|" + Self.single + "|" + Self.backtick
        attribute = #"@[\w.]+"#
        keywords = """
          abstract any as async await boolean break case catch class const constructor continue debugger declare \
          default delete do else enum export extends false finally for from function get if implements import in \
          infer instanceof interface keyof let namespace never new null number of private protected public readonly \
          return satisfies set static string super switch this throw true try type typeof undefined unknown var void \
          while with yield
          """
      case .swift:
        comment = Self.slashComment
        string = #"#*""".*?(?:"""|$)|#*"# + Self.double
        attribute = #"@\w+|#\w+"#
        keywords = """
          actor any as associatedtype async await break case catch class continue default defer deinit do else enum \
          extension fallthrough false fileprivate final for func guard if import in indirect init inout internal is \
          lazy let mutating nil nonisolated open operator override private protocol public repeat rethrows return \
          self Self some static struct subscript super switch throw throws true try typealias var weak where while \
          get set willSet didSet unowned convenience required
          """
      case .go:
        comment = Self.slashComment
        string = Self.double + "|" + Self.backtick + #"|'(?:\\.|[^'\\])'"#
        keywords = """
          break case chan const continue default defer else fallthrough false for func go goto if import interface \
          iota map nil package range return select struct switch true type var
          """
      case .rust:
        comment = Self.slashComment
        string = ##"b?r#*".*?(?:"#*|$)|b?"## + Self.double + #"|'(?:\\.|[^'\\])'"#
        attribute = #"#!?\[[^\]]*\]?"#
        bangCalls = true
        keywords = """
          as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod \
          move mut pub ref return self Self static struct super trait true type unsafe use where while
          """
      case .cLike:
        comment = Self.slashComment + #"|^\s*#\s*\w+"#
        string = Self.double + #"|'(?:\\.|[^'\\])*'"#
        attribute = #"@\w+"#
        keywords = """
          abstract auto bool break case catch char class const continue default delete do double else enum extends \
          extern false final finally float for fun goto if implements import int interface long namespace new null \
          nullptr object override package private protected public return short signed sizeof static struct super \
          switch template this throw throws true try typedef typename union unsigned using val var virtual void \
          volatile when while
          """
      case .shell:
        comment = Self.hashComment
        string = Self.double + #"|'[^']*'?"#
        attribute = #"\$(?:\{[^}]*\}?|\w+|[@#?$!*0-9])"#
        capitals = false
        keywords = """
          if then else elif fi for while until do done case esac in function return local export readonly unset \
          shift exit break continue source alias set echo cd true false
          """
      case .ruby:
        comment = Self.hashComment
        string = Self.double + "|" + Self.single + #"|:\w+"#
        attribute = #"@{1,2}\w+"#
        word = #"[A-Za-z_][\w]*[?!]?"#
        keywords = """
          alias and begin break case class def defined? do else elsif end ensure false for if in module next nil not \
          or redo require rescue retry return self super then true undef unless until when while yield attr_reader \
          attr_accessor private protected public
          """
      case .json:
        string = Self.double
        property = #""(?:\\.|[^"\\])*"(?=\s*:)"#
        capitals = false
        keywords = "true false null"
      case .yaml:
        comment = Self.hashComment
        property = #"^\s*(?:-\s+)?[\w.\-/ ]+?(?=\s*[:=](?:\s|$))|^\s*\[[^\]]*\]"#
        string = Self.double + "|" + Self.single
        attribute = #"[&*][\w-]+"#
        capitals = false
        keywords = "true false null yes no on off True False"
      case .css:
        comment = #"/\*.*?(?:\*/|$)|^\s*\*.*$|//.*"#
        string = Self.double + "|" + Self.single
        property = #"(?<![\w-])--?[a-zA-Z][\w-]*(?=\s*:)|(?<![\w-])[a-z][\w-]*(?=\s*:\s)"#
        attribute = #"#[0-9a-fA-F]{3,8}\b|[.#][a-zA-Z_][\w-]*|@[\w-]+|\$[\w-]+"#
        capitals = false
        word = #"[a-zA-Z_][\w-]*"#
        keywords = "important inherit initial unset none auto"
      case .html:
        comment = #"<!--.*?(?:-->|$)"#
        tag = #"</?[A-Za-z][\w:.-]*|/?>"#
        property = #"[\w:@.-]+(?==)"#
        string = Self.double + "|" + Self.single
        capitals = false
      case .markdown:
        tag = #"^\s{0,3}#{1,6}\s.*$|^\s*(?:[-*+]|\d+\.)\s|^\s*>"#
        string = #"`[^`]*`?|\*\*[^*]+\*\*"#
        property = #"\[[^\]]*\]\([^)]*\)"#
        capitals = false
      case .sql:
        comment = #"--.*|/\*.*?(?:\*/|$)"#
        string = #"'(?:''|[^'])*'?"# + "|" + Self.double
        capitals = false
        keywords = """
          select from where and or not insert into values update set delete create table alter drop index on join \
          left right inner outer group by order having limit offset as distinct null is in like between case when \
          then else end primary key foreign references default union all exists returning with
          SELECT FROM WHERE AND OR NOT INSERT INTO VALUES UPDATE SET DELETE CREATE TABLE ALTER DROP INDEX ON JOIN \
          LEFT RIGHT INNER OUTER GROUP BY ORDER HAVING LIMIT OFFSET AS DISTINCT NULL IS IN LIKE BETWEEN CASE WHEN \
          THEN ELSE END PRIMARY KEY FOREIGN REFERENCES DEFAULT UNION ALL EXISTS RETURNING WITH
          """
      }

      let alternatives: [(String, String?, Kind)] = [
        ("comment", comment, .comment), ("tag", tag, .keyword), ("property", property, .property),
        ("string", string, .string), ("number", Self.number, .number), ("attribute", attribute, .attribute),
      ]
      let present = alternatives.compactMap { name, pattern, kind in pattern.map { (name, $0, kind) } }
      let pattern = (present.map { "(?<\($0.0)>\($0.1))" } + ["(?<word>\(word))"]).joined(separator: "|")
      // The patterns above are fixed, and the tests compile every language's.
      let regex = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
      let words = keywords.split(whereSeparator: \.isWhitespace).map(String.init)
      return Grammar(regex: regex, keywords: Set(words), capitals: capitals, bangCalls: bangCalls,
                     groups: present.map { ($0.0, $0.2) })
    }
  }
}
