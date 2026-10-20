import Foundation

/// Where a command in the ↑ list comes from (spec "S2: history", "↑ list"): this tab, this folder (other tabs and
/// earlier sessions), or anywhere else.
public enum HistorySection: Sendable {
  case tab, folder, everywhere
}

/// What ⌃R searches; Tab steps through them in this order.
public enum HistoryScope: String, CaseIterable, Sendable {
  case all, folder, tab

  public var next: HistoryScope {
    switch self {
    case .all: .folder
    case .folder: .tab
    case .tab: .all
    }
  }

  public var title: String {
    switch self {
    case .all: "All"
    case .folder: "Folder"
    case .tab: "Tab"
    }
  }
}

/// Glance's history in memory: one entry per distinct command, with what the lists and the ranking need. Built from
/// the store at launch and kept up to date with each run.
public struct CommandIndex: Sendable {
  public struct Place: Equatable, Sendable {
    public var count: Int
    public var last: Date
    /// How the newest run here ended (nil: imported, or unknown).
    public var lastExit: Int?

    public init(count: Int, last: Date, lastExit: Int? = nil) {
      self.count = count
      self.last = last
      self.lastExit = lastExit
    }
  }

  public struct Entry: Equatable, Sendable {
    public let command: String
    public internal(set) var count = 0
    /// Runs recorded in Studio (the rest were imported from zsh's file).
    public internal(set) var recordedCount = 0
    public internal(set) var lastStart = Date.distantPast
    public internal(set) var lastExit: Int?
    public internal(set) var lastFolder: String?
    public internal(set) var lastDuration: TimeInterval?
    public internal(set) var folders: [String: Place] = [:]
    /// The same per git repository (the record's `gitRoot`), so a command run anywhere in a project counts for all of it.
    public internal(set) var projects: [String: Place] = [:]
    /// When it last ran in each tab.
    public internal(set) var tabs: [String: Date] = [:]

    init(command: String) { self.command = command }

    private static func bump(_ place: inout Place?, _ record: CommandRecord) {
      var current = place ?? Place(count: 0, last: .distantPast)
      current.count += 1
      if record.start >= current.last { current.lastExit = record.exitCode }
      current.last = max(current.last, record.start)
      place = current
    }

    mutating func add(_ record: CommandRecord) {
      count += 1
      if !record.imported { recordedCount += 1 }
      if record.start >= lastStart {
        lastStart = record.start
        lastExit = record.exitCode
        lastFolder = record.folder
        lastDuration = record.duration
      }
      if let folder = record.folder {
        Self.bump(&folders[folder], record)
      }
      if let root = record.gitRoot { Self.bump(&projects[root], record) }
      if let tab = record.tab { tabs[tab] = max(tabs[tab] ?? .distantPast, record.start) }
    }
  }

  private var byCommand: [String: Entry] = [:]
  /// What followed what (spec "S3: ghost text and ranking"): the previous command's template → the next command's
  /// template → how often, for consecutive runs less than an hour apart in one tab (or in zsh's file).
  public private(set) var transitions: [String: [String: Int]] = [:]
  /// The same, per folder the next command ran in.
  public private(set) var folderTransitions: [String: [String: [String: Int]]] = [:]
  /// The run before the next one, per tab (and for the imported file, under "").
  private var lastRun: [String: (template: String, start: Date)] = [:]
  static let habitGap: TimeInterval = 3600

  /// `records` oldest first, as the store gives them.
  public init(_ records: [CommandRecord] = []) {
    for record in records { add(record) }
  }

  public var entries: [Entry] { Array(byCommand.values) }
  public var isEmpty: Bool { byCommand.isEmpty }
  public func entry(_ command: String) -> Entry? { byCommand[command] }

  public mutating func add(_ record: CommandRecord) {
    byCommand[record.command, default: Entry(command: record.command)].add(record)
    // A stream of consecutive runs: the tab's, or the imported file's.
    guard let stream = record.tab ?? (record.imported ? "" : nil) else { return }
    let template = GhostSuggester.template(record.command).text
    if let previous = lastRun[stream], record.start >= previous.start,
       record.start.timeIntervalSince(previous.start) < Self.habitGap {
      transitions[previous.template, default: [:]][template, default: 0] += 1
      if let folder = record.folder {
        folderTransitions[folder, default: [:]][previous.template, default: [:]][template, default: 0] += 1
      }
    }
    lastRun[stream] = (template, record.start)
  }

  /// How often `command` followed `previous` (0…1), by their templates.
  public func transitionShare(from previous: String, to command: String) -> Double {
    guard let next = transitions[GhostSuggester.template(previous).text] else { return 0 }
    let total = next.values.reduce(0, +)
    guard total > 0 else { return 0 }
    return Double(next[GhostSuggester.template(command).text] ?? 0) / Double(total)
  }

  /// Forgets a command (⌘⌫), with what it followed and what followed it once no other command shares its template, so
  /// the next-command prediction can't bring it back.
  public mutating func remove(command: String) {
    byCommand[command] = nil
    let template = GhostSuggester.template(command).text
    guard !byCommand.keys.contains(where: { GhostSuggester.template($0).text == template }) else { return }
    transitions[template] = nil
    for key in transitions.keys { transitions[key]?[template] = nil }
    for folder in folderTransitions.keys {
      folderTransitions[folder]?[template] = nil
      for key in folderTransitions[folder]?.keys.map({ $0 }) ?? [] { folderTransitions[folder]?[key]?[template] = nil }
    }
  }

  // MARK: - Context

  /// Commands that worked before, for fixing a mistyped one: where they last succeeded decides `here` (this folder, else
  /// this repository), most used first. Imported lines have no outcome and count as worked.
  public func worked(folder: String?, gitRoot: String?, limit: Int = 2000) -> [PastCommand] {
    var past: [PastCommand] = []
    for entry in byCommand.values {
      let place = folder.flatMap { entry.folders[$0] } ?? gitRoot.flatMap { entry.projects[$0] }
      let exit = place?.lastExit ?? entry.lastExit
      guard exit == nil || exit == 0, !entry.command.contains("\n") else { continue }
      past.append(PastCommand(command: entry.command, count: entry.count, here: place != nil))
    }
    past.sort { a, b in
      if a.here != b.here { return a.here }
      if a.count != b.count { return a.count > b.count }
      return a.command < b.command
    }
    return Array(past.prefix(limit))
  }

  // MARK: - The ↑ list

  /// The ↑ list: each command once, this tab's first (newest first), then this folder's, then the rest; `typed`
  /// narrows it, prefix matches before substring ones within each part. When nothing matches exactly, a typo is
  /// forgiven: `pnpf de` finds pnpm dev. Commands that wouldn't run (`runs` false) are left out.
  public func upList(typed: String, tab: String?, folder: String?, gitRoot: String? = nil, limit: Int = 300,
                     runs: (String) -> Bool = { _ in true }) -> [HistoryRow] {
    let rows = upList(typed: typed, tab: tab, folder: folder, gitRoot: gitRoot, limit: limit, typos: false, runs: runs)
    guard rows.isEmpty, !typed.allSatisfy(\.isWhitespace) else { return rows }
    return upList(typed: typed, tab: tab, folder: folder, gitRoot: gitRoot, limit: limit, typos: true, runs: runs)
  }

  private func upList(typed: String, tab: String?, folder: String?, gitRoot: String?, limit: Int, typos: Bool,
                      runs: (String) -> Bool) -> [HistoryRow] {
    var rows: [(row: HistoryRow, prefix: Bool, when: Date, part: Int)] = []
    for entry in byCommand.values {
      let match: (prefix: Bool, ranges: [Range<Int>])
      if typos {
        guard let ranges = Self.typoMatch(typed, in: entry.command) else { continue }
        match = (true, ranges)
      } else if typed.isEmpty {
        match = (true, [])
      } else if entry.command.hasPrefix(typed) {
        match = (true, [0..<typed.count])
      } else if let range = Self.find(typed.lowercased(), in: Self.lowered(entry.command)) {
        match = (false, [range])
      } else {
        continue
      }
      guard runs(entry.command) else { continue }
      let section: HistorySection
      let when: Date
      if let tab, let last = entry.tabs[tab] {
        (section, when) = (.tab, last)
      } else if let folder, let place = entry.folders[folder] {
        (section, when) = (.folder, place.last)
      } else if let gitRoot, let place = entry.projects[gitRoot] {
        (section, when) = (.folder, place.last)
      } else {
        (section, when) = (.everywhere, entry.lastStart)
      }
      let part = section == .tab ? 0 : section == .folder ? 1 : 2
      rows.append((HistoryRow(entry: entry, section: section, highlight: match.ranges), match.prefix, when, part))
    }
    rows.sort { a, b in
      if a.part != b.part { return a.part < b.part }
      if a.prefix != b.prefix { return a.prefix }
      if a.when != b.when { return a.when > b.when }
      return a.row.entry.command < b.row.entry.command
    }
    return rows.prefix(limit).map(\.row)
  }

  // MARK: - ⌃R

  /// ⌃R: every word of `query` somewhere in the command, in any order (a single word may also match as a
  /// subsequence). Best first: words found at word starts, in order, recent, frequent; a failed last run sorts lower.
  /// Commands that wouldn't run (`runs` false) are left out.
  public func search(_ query: String, scope: HistoryScope, tab: String?, folder: String?, now: Date = Date(),
                     limit: Int = 300, runs: (String) -> Bool = { _ in true }) -> [HistoryHit] {
    let terms = query.split(whereSeparator: \.isWhitespace).map { String($0).lowercased() }
    var hits: [HistoryHit] = []
    for entry in byCommand.values {
      switch scope {
      case .all: break
      case .folder: guard let folder, entry.folders[folder] != nil else { continue }
      case .tab: guard let tab, entry.tabs[tab] != nil else { continue }
      }
      guard runs(entry.command) else { continue }
      let age = max(0, now.timeIntervalSince(entry.lastStart)) / 86_400
      var score = 2 * exp(-age / 14) + 0.5 * log2(1 + Double(entry.count))
      if let exit = entry.lastExit, exit != 0 { score -= 1.5 }
      if entry.recordedCount == 0 { score -= 0.25 }
      guard !terms.isEmpty else {
        hits.append(HistoryHit(entry: entry, highlight: [], score: entry.lastStart.timeIntervalSince1970))
        continue
      }
      let text = Self.lowered(entry.command)
      var ranges: [Range<Int>] = []
      var found = true
      for term in terms {
        guard let range = Self.find(term, in: text, preferWordStart: true) else {
          found = false
          break
        }
        score += Self.isWordStart(range.lowerBound, in: text) ? 2 : 1
        ranges.append(range)
      }
      if !found {
        guard terms.count == 1, terms[0].count >= 2, let fuzzy = Self.subsequence(terms[0], in: text),
              let first = fuzzy.first, let last = fuzzy.last else { continue }
        ranges = fuzzy
        // A tight match beats a scattered one (`gst`: git status over grep -r stuff).
        score -= 2 + 0.05 * Double(last.upperBound - first.lowerBound)
      } else if ranges.count > 1, zip(ranges, ranges.dropFirst()).allSatisfy({ $0.lowerBound < $1.lowerBound }) {
        score += 1
      }
      hits.append(HistoryHit(entry: entry, highlight: Self.merged(ranges), score: score))
    }
    hits.sort { a, b in
      if a.score != b.score { return a.score > b.score }
      if a.entry.lastStart != b.entry.lastStart { return a.entry.lastStart > b.entry.lastStart }
      return a.entry.command < b.entry.command
    }
    return Array(hits.prefix(limit))
  }

  // MARK: - Matching

  static func lowered(_ text: String) -> [Character] {
    text.map { $0.lowercased().first ?? $0 }
  }

  /// The first place `needle` occurs in `hay` (characters), at a word start when `preferWordStart` and there is one.
  static func find(_ needle: String, in hay: [Character], preferWordStart: Bool = false) -> Range<Int>? {
    let n = Array(needle)
    guard !n.isEmpty, n.count <= hay.count else { return nil }
    var first: Range<Int>?
    for start in 0...(hay.count - n.count) where hay[start] == n[0] && Array(hay[start..<(start + n.count)]) == n {
      let range = start..<(start + n.count)
      if !preferWordStart || isWordStart(start, in: hay) { return range }
      if first == nil { first = range }
    }
    return first
  }

  static func isWordStart(_ index: Int, in text: [Character]) -> Bool {
    index == 0 || !(text[index - 1].isLetter || text[index - 1].isNumber)
  }

  static func subsequence(_ needle: String, in hay: [Character]) -> [Range<Int>]? {
    var ranges: [Range<Int>] = []
    var n = Array(needle)[...]
    for (i, character) in hay.enumerated() where n.first == character {
      n = n.dropFirst()
      if let last = ranges.last, last.upperBound == i { ranges[ranges.count - 1] = last.lowerBound..<(i + 1) } else {
        ranges.append(i..<(i + 1))
      }
      if n.isEmpty { return ranges }
    }
    return nil
  }

  /// `typed` as the start of `command` with a typo or two: each typed word against the command's word in the same
  /// place, within an edit distance of 0 for one or two characters, 1 up to five, 2 beyond; the word still being typed
  /// may be the start of its word. The ranges are the matched words.
  static func typoMatch(_ typed: String, in command: String) -> [Range<Int>]? {
    let typedWords = typed.split(whereSeparator: \.isWhitespace).map { String($0).lowercased() }
    let text = lowered(command)
    var words: [Range<Int>] = []
    var start: Int?
    for (i, character) in text.enumerated() {
      if character.isWhitespace {
        if let s = start { words.append(s..<i) }
        start = nil
      } else if start == nil {
        start = i
      }
    }
    if let start { words.append(start..<text.count) }
    guard !typedWords.isEmpty, typedWords.count <= words.count else { return nil }
    let typing = !(typed.last?.isWhitespace ?? true)
    var ranges: [Range<Int>] = []
    for (i, word) in typedWords.enumerated() {
      let allowed = word.count <= 2 ? 0 : word.count <= 5 ? 1 : 2
      let target = words[i]
      let candidate = String(text[target])
      if typing, i == typedWords.count - 1 {
        // The best start of the word, a character shorter or longer than what's typed.
        let shortest = max(1, word.count - 1), longest = min(candidate.count, word.count + 1)
        guard shortest <= longest else { return nil }
        let best = (shortest...longest).map { (length: $0, distance: distance(word, String(candidate.prefix($0)))) }
          .min { $0.distance < $1.distance }!
        guard best.distance <= allowed else { return nil }
        ranges.append(target.lowerBound..<(target.lowerBound + best.length))
      } else {
        guard distance(word, candidate) <= allowed else { return nil }
        ranges.append(target)
      }
    }
    return ranges
  }

  /// Edit distance with adjacent swaps.
  static func distance(_ a: String, _ b: String) -> Int { Corrections.distance(a, b) }

  static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
    var out: [Range<Int>] = []
    for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
      if let last = out.last, range.lowerBound <= last.upperBound {
        out[out.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
      } else {
        out.append(range)
      }
    }
    return out
  }
}

/// A command that worked before (`CommandIndex.worked`).
public struct PastCommand: Equatable, Sendable {
  public let command: String
  public let count: Int
  /// It ran in the folder (or repository) asked about.
  public let here: Bool

  public init(command: String, count: Int, here: Bool) {
    self.command = command
    self.count = count
    self.here = here
  }
}

/// A command in the ↑ list.
public struct HistoryRow: Equatable, Sendable, Identifiable {
  public let entry: CommandIndex.Entry
  public let section: HistorySection
  /// Character ranges of the command the typed text matched.
  public let highlight: [Range<Int>]
  public var id: String { entry.command }
}

/// A command ⌃R found.
public struct HistoryHit: Equatable, Sendable, Identifiable {
  public let entry: CommandIndex.Entry
  public let highlight: [Range<Int>]
  public let score: Double
  public var id: String { entry.command }
}
