import Foundation

/// The ghost text after the line (spec "S3: ghost text and ranking"): the part of a suggestion not typed yet, and where
/// accepting it leaves the cursor (nil: at the end).
public struct GhostSuggestion: Equatable, Sendable {
  public let text: String
  public let cursor: Int?

  public init(text: String, cursor: Int?) {
    self.text = text
    self.cursor = cursor
  }
}

/// What the suggester knows about the moment: the line, where it's typed, the command before it, the shell's command
/// names, and a way to look at files.
public struct GhostContext {
  public var line: String
  public var folder: String
  public var tab: String?
  /// The repository the folder is in, so commands from its other folders count too.
  public var gitRoot: String?
  public var previous: String?
  public var now: Date
  /// Commands, aliases, functions and builtins the shell has.
  public var names: Set<String>
  /// Whether a path exists (absolute, `~/…`, or relative to `folder`).
  public var exists: (String) -> Bool
  /// A folder's entries (absolute, `~/…` or relative to `folder`), folders ending in `/`; nil when it can't be read.
  public var list: (String) -> [String]?
  /// Whether a past command would run here (its command names known); one that wouldn't is never suggested.
  public var runs: (String) -> Bool = { _ in true }

  public init(line: String, folder: String, tab: String?, previous: String?, now: Date, names: Set<String>,
              exists: @escaping (String) -> Bool, list: @escaping (String) -> [String]?) {
    self.line = line
    self.folder = folder
    self.tab = tab
    self.previous = previous
    self.now = now
    self.names = names
    self.exists = exists
    self.list = list
  }
}

/// Deterministic ghost text, no model: history first (commands that start with the line, scored by folder, habit,
/// success, recency and frequency, minus any whose paths are gone), then light completion (a command name for the
/// first word, a file for a path), and on an empty line the usual next command.
public enum GhostSuggester {
  /// The score's weights (spec "S3", "Score": fixed, set with the replay check on real history).
  public struct Weights: Equatable, Sendable {
    public var frequency = 1.0
    public var recency = 2.0
    /// Hours for recency to fall to 1/e.
    public var recencyHours = 72.0
    public var folder = 2.5
    public var folderBase = 0.5
    /// Run elsewhere in this repository (less than the folder itself).
    public var project = 1.0
    /// Run in a folder above or below this one.
    public var nearby = 0.5
    public var tab = 0.5
    public var habit = 3.0
    public var success = 0.5
    public var failure = 2.0
    public var importedOnly = 0.5

    public init() {}
    public static let standard = Weights()
  }

  public static func suggest(_ index: CommandIndex, _ context: GhostContext,
                             weights: Weights = .standard) -> GhostSuggestion? {
    let line = context.line
    guard !line.isEmpty, !line.hasPrefix(" "), !line.contains("\n") else { return nil }
    var best: (entry: CommandIndex.Entry, score: Double)?
    for entry in index.entries where entry.command.count > line.count && entry.command.hasPrefix(line) {
      guard !entry.command.contains("\n"), pathsExist(entry.command, typed: line, context),
            context.runs(entry.command) else { continue }
      let score = score(entry, context, index, weights)
      if best == nil || score > best!.score || (score == best!.score && entry.command < best!.entry.command) {
        best = (entry, score)
      }
    }
    if let best { return GhostSuggestion(text: String(best.entry.command.dropFirst(line.count)), cursor: nil) }
    return complete(index, context)
  }

  /// How likely a past command is what's being typed now.
  public static func score(_ entry: CommandIndex.Entry, _ context: GhostContext, _ index: CommandIndex,
                            _ w: Weights = .standard) -> Double {
    let hours = max(0, context.now.timeIntervalSince(entry.lastStart)) / 3600
    var score = w.frequency * log(1 + Double(entry.count)) + w.recency * exp(-hours / w.recencyHours)
    if let place = entry.folders[context.folder] {
      score += w.folderBase + w.folder * Double(place.count) / Double(max(entry.count, 1))
    } else if let root = context.gitRoot, let place = entry.projects[root] {
      score += w.project * (0.5 + Double(place.count) / Double(max(entry.count, 1)))
    } else if entry.folders.keys.contains(where: { isNearby($0, context.folder) }) {
      score += w.nearby
    }
    if let tab = context.tab, entry.tabs[tab] != nil { score += w.tab }
    if let previous = context.previous { score += w.habit * index.transitionShare(from: previous, to: entry.command) }
    // How it ended here counts over how it ended anywhere (the same command can work in another project).
    let ended = entry.folders[context.folder]?.lastExit ?? context.gitRoot.flatMap { entry.projects[$0]?.lastExit }
      ?? entry.lastExit
    if let exit = ended { score += exit == 0 ? w.success : -w.failure }
    if entry.recordedCount == 0 { score -= w.importedOnly }
    return score
  }

  /// One folder is the other's ancestor or descendant (`/proj` and `/proj/web`).
  static func isNearby(_ a: String, _ b: String) -> Bool {
    guard a != b, !a.isEmpty, !b.isEmpty, a != "/", b != "/" else { return false }
    return a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
  }

  /// On an empty prompt right after `previous`: what usually comes next in this folder (else anywhere), when it came
  /// next at least 3 times and at least 40% of the time. Quotes that change each time come empty, the cursor in them.
  public static func next(_ index: CommandIndex, previous: String, folder: String) -> GhostSuggestion? {
    let key = template(previous).text
    for table in [index.folderTransitions[folder]?[key] ?? [:], index.transitions[key] ?? [:]] {
      let total = table.values.reduce(0, +)
      guard let top = table.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }),
            top.value >= 3, Double(top.value) / Double(total) >= 0.4 else { continue }
      return GhostSuggestion(text: top.key, cursor: emptyQuoteCursor(top.key))
    }
    return nil
  }

  /// The command with every quoted part emptied (`git commit -m "fix it"` → `git commit -m ""`), and the cursor
  /// inside the first emptied quotes (in zsh's units, Unicode scalars), nil when there are none.
  public static func template(_ command: String) -> (text: String, cursor: Int?) {
    guard command.contains("'") || command.contains("\"") else { return (command, nil) }
    var out = String.UnicodeScalarView()
    var cursor: Int?
    var quote: Unicode.Scalar?
    var escaped = false
    for scalar in command.unicodeScalars {
      if let open = quote {
        if escaped { escaped = false; continue }
        if scalar == "\\" && open == "\"" { escaped = true; continue }
        if scalar == open {
          out.append(scalar)
          quote = nil
        }
        continue
      }
      if escaped {
        out.append(scalar)
        escaped = false
        continue
      }
      if scalar == "\\" {
        out.append(scalar)
        escaped = true
      } else if scalar == "'" || scalar == "\"" {
        out.append(scalar)
        if cursor == nil { cursor = out.count }
        quote = scalar
      } else {
        out.append(scalar)
      }
    }
    return (String(out), cursor)
  }

  static func emptyQuoteCursor(_ text: String) -> Int? {
    let scalars = Array(text.unicodeScalars)
    for i in scalars.indices.dropLast() where (scalars[i] == "\"" || scalars[i] == "'") && scalars[i + 1] == scalars[i] {
      return i + 1
    }
    return nil
  }

  // MARK: - Paths

  /// The suggestion's paths that the user hasn't typed yet all exist (fish's check): a word with a slash, one starting
  /// `./`, `../` or `~/`, and `cd`'s argument.
  static func pathsExist(_ command: String, typed: String, _ context: GhostContext) -> Bool {
    let words = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    var consumed = 0
    for (position, word) in words.enumerated() {
      let start = command.range(of: word, range: command.index(command.startIndex, offsetBy: consumed)..<command.endIndex)
      let end = start.map { command.distance(from: command.startIndex, to: $0.upperBound) } ?? consumed
      defer { consumed = end }
      // Words wholly typed already are the user's business.
      if end <= typed.count { continue }
      guard isPathLike(word) || (position == 1 && ["cd", "pushd"].contains(words[0]) && !word.hasPrefix("-")) else {
        continue
      }
      if !context.exists(word) { return false }
    }
    return true
  }

  static func isPathLike(_ word: String) -> Bool {
    guard !word.hasPrefix("-"), !word.contains("://"), !word.contains("$"),
          !word.contains(where: { "*?[]{}'\"`=".contains($0) }) else { return false }
    return word.contains("/") || word.hasPrefix("./") || word.hasPrefix("../") || word.hasPrefix("~/")
  }

  // MARK: - Light completion

  static func complete(_ index: CommandIndex, _ context: GhostContext) -> GhostSuggestion? {
    let line = context.line
    let words = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    if words.count == 1 {
      let typed = words[0]
      guard typed.count >= 2 else { return nil }
      // The command you use most that starts so, else the shortest name the shell knows.
      var used: [String: Int] = [:]
      for entry in index.entries {
        guard let first = entry.command.split(separator: " ").first.map(String.init),
              first.count > typed.count, first.hasPrefix(typed), context.runs(first) else { continue }
        used[first, default: 0] += entry.count
      }
      if let top = used.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) {
        return GhostSuggestion(text: String(top.key.dropFirst(typed.count)), cursor: nil)
      }
      let known = context.names.filter { $0.count > typed.count && $0.hasPrefix(typed) }
        .min { $0.count != $1.count ? $0.count < $1.count : $0 < $1 }
      return known.map { GhostSuggestion(text: String($0.dropFirst(typed.count)), cursor: nil) }
    }
    guard let last = words.last, isPathLike(last) || last.hasPrefix(".") || last.hasPrefix("~") else { return nil }
    let slash = last.lastIndex(of: "/")
    let folder = slash.map { String(last[...$0]) } ?? ""
    let base = slash.map { String(last[last.index(after: $0)...]) } ?? last
    guard let entries = context.list(folder.isEmpty ? "." : String(folder.dropLast(folder.count > 1 ? 1 : 0))) else {
      return nil
    }
    let matches = entries.filter { $0.hasPrefix(base) && $0 != base && (base.hasPrefix(".") || !$0.hasPrefix(".")) }
    guard let first = matches.first else { return nil }
    var shared = first
    for match in matches.dropFirst() { shared = String(shared.commonPrefix(with: match)) }
    guard shared.count > base.count else { return nil }
    return GhostSuggestion(text: String(shared.dropFirst(base.count)), cursor: nil)
  }
}
