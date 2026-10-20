import Foundation

/// The editor sheet's fields, as the strings the user typed. The value field is empty when editing: empty keeps the
/// saved value, which the sheet never shows unless revealed with Touch ID. `record(...)` parses the strings and leaves
/// every rule to `SecretRecord.problems` and `SecretHostRule.problem`, so the sheet and the vault agree.
public struct SecretDraft: Equatable, Sendable {
  public enum SlotKind: String, CaseIterable, Sendable { case bearer, header, basic }

  public var name = ""
  public var note = ""
  public var value = ""
  /// Separated by commas, spaces or line breaks.
  public var hosts = ""
  public var slotKind: SlotKind = .bearer
  public var headerName = "X-API-Key"
  public var headerPrefix = ""
  public var username = ""
  /// Absolute paths. Empty: any folder.
  public var folders: [String] = []
  public var approval: SecretApproval = .everyTime
  /// The saved secret's `updated` when this draft was made from it; nil for a new secret. `SecretsModel.update` refuses
  /// to save over a secret that changed since.
  public var baseUpdated: Date?

  /// What stops a save, as sentences for the sheet (`[String]` can't be a `Result`'s failure: arrays aren't `Error`s).
  public struct Problems: Error, Equatable, Sendable, RandomAccessCollection, ExpressibleByArrayLiteral {
    public let sentences: [String]
    public init(_ sentences: [String]) { self.sentences = sentences }
    public init(arrayLiteral elements: String...) { sentences = elements }
    public var startIndex: Int { sentences.startIndex }
    public var endIndex: Int { sentences.endIndex }
    public subscript(position: Int) -> String { sentences[position] }
  }

  public init() {}

  /// The fields of a saved secret. The value stays empty: the sheet doesn't hold it.
  public init(record: SecretRecord) {
    name = record.name
    note = record.note
    hosts = record.hosts.joined(separator: ", ")
    switch record.slot {
    case .bearer: slotKind = .bearer
    case .header(let name, let prefix): slotKind = .header; headerName = name; headerPrefix = prefix
    case .basic(let user): slotKind = .basic; username = user
    }
    folders = record.folders
    approval = record.approval
    baseUpdated = record.updated
  }

  /// The hosts typed in `hosts`: split on commas and any white space or line break (by unicode scalar: Swift folds
  /// "\r\n" into one Character that equals neither "\r" nor "\n"), lowercased and without a trailing dot when they
  /// are host names (anything else is kept as typed, so the sheet can say what is wrong with it), each once.
  public var hostList: [String] {
    var parts: [String] = []
    var current = String.UnicodeScalarView()
    for scalar in hosts.unicodeScalars {
      if scalar == "," || CharacterSet.whitespacesAndNewlines.contains(scalar) {
        if !current.isEmpty { parts.append(String(current)); current = String.UnicodeScalarView() }
      } else {
        current.append(scalar)
      }
    }
    if !current.isEmpty { parts.append(String(current)) }
    var seen = Set<String>()
    var list: [String] = []
    for part in parts {
      let host = SecretHostRule.normalize(part) ?? part
      if seen.insert(host).inserted { list.append(host) }
    }
    return list
  }

  /// Only the chosen kind's fields count; the others are ignored.
  public var slot: SecretSlot {
    switch slotKind {
    case .bearer: .bearer
    case .header: .header(name: headerName.trimmingCharacters(in: .whitespacesAndNewlines), prefix: headerPrefix)
    case .basic: .basic(username: username)
    }
  }

  /// `keeping`: the saved value, used when the value field was left empty. Failure: the sentences for the sheet.
  public func record(id: UUID, created: Date, now: Date, otherNames: Set<String>,
                     keeping: String?, home: String = NSHomeDirectory()) -> Result<SecretRecord, Problems> {
    let value = self.value.isEmpty ? (keeping ?? "") : self.value
    let record = SecretRecord(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                              note: note.trimmingCharacters(in: .whitespacesAndNewlines), value: value,
                              hosts: hostList, slot: slot, folders: uniqueFolders, approval: approval, created: created,
                              updated: now)
    var problems = record.problems(otherNames: otherNames)
    // `always` sends without asking, so it has to name where (the picker says "in these folders").
    if approval == .always {
      if folders.isEmpty {
        problems.append("\"Always\" needs at least one folder. Add one, or ask every time.")
      } else if folders.contains(where: { Self.isTooWide($0, home: home) }) {
        problems.append("Always needs a project folder, not / or your home folder.")
      }
    }
    return problems.isEmpty ? .success(record) : .failure(Problems(problems))
  }

  /// "/", the home folder, or any folder above it (compared after standardizing and resolving links, ignoring case: the
  /// usual Mac volume doesn't care): a fence that wide is no fence.
  static func isTooWide(_ folder: String, home: String) -> Bool {
    // Several spellings: NSString leaves "/." alone, URL leaves "//" alone, /var is /private/var, and the data volume's
    // firmlink makes /System/Volumes/Data/Users/me the same folder as /Users/me.
    func keys(_ path: String) -> Set<String> {
      let url = URL(fileURLWithPath: path)
      return Set([(path as NSString).standardizingPath, url.standardizedFileURL.path, url.resolvingSymlinksInPath().path]
        .map { spelling in
          let lower = spelling.lowercased()
          let firmlink = "/system/volumes/data"
          if lower == firmlink { return "/" }
          return lower.hasPrefix(firmlink + "/") ? String(lower.dropFirst(firmlink.count)) : lower
        })
    }
    let homes = keys(home)
    return keys(folder).contains { fence in
      fence == "/" || homes.contains { $0 == fence || $0.hasPrefix(fence + "/") }
    }
  }

  private var uniqueFolders: [String] {
    var seen = Set<String>()
    return folders.filter { seen.insert($0).inserted }
  }

  // MARK: - What a save changes

  /// The phrases for the changes to a secret's value or rules between two versions ([] when only the name or note
  /// changed, or nothing did), most dangerous first: approval, folders, hosts, how it is sent, the value. Folders and
  /// hosts get one phrase for what was added and one for what was removed, each showing ONE quoted item and a count.
  /// `itemLimit` caps that item in characters (0: no item, only the count; below 0: only the count, and a header slot
  /// doesn't add "with prefix", the shortest form `changeReason` falls back to).
  public static func ruleChanges(from old: SecretRecord, to new: SecretRecord, itemLimit: Int = 32) -> [String] {
    var changes: [String] = []
    if old.approval != new.approval {
      switch new.approval {
      case .everyTime: changes.append("ask every time")
      case .oncePerSession: changes.append("ask once per session")
      case .always: changes.append("Always")
      }
    }
    if Set(old.folders) != Set(new.folders) {
      if new.folders.isEmpty {
        changes.append("any folder")
      } else if old.folders.isEmpty {
        changes.append(group("only in", "folder", new.folders, itemLimit))
      } else {
        let added = new.folders.filter { !old.folders.contains($0) }
        let removed = old.folders.filter { !new.folders.contains($0) }
        if !added.isEmpty { changes.append(group("adds", "folder", added, itemLimit)) }
        if !removed.isEmpty { changes.append(group("removes", "folder", removed, itemLimit)) }
      }
    }
    if Set(old.hosts) != Set(new.hosts) {
      let added = new.hosts.filter { !old.hosts.contains($0) }
      let removed = old.hosts.filter { !new.hosts.contains($0) }
      if !added.isEmpty { changes.append(group("adds", "host", added, itemLimit)) }
      if !removed.isEmpty { changes.append(group("removes", "host", removed, itemLimit)) }
    }
    if old.slot != new.slot { changes.append(describe(new.slot, itemLimit)) }
    if old.value != new.value { changes.append("a new value") }
    return changes
  }

  /// The Touch ID reason for saving a change from `old` to `new`, or nil when it changes no value or rule. It always
  /// names every changed kind, and the approval word when the approval changed, and nothing is cut off the end: names
  /// are cut to 24 characters, and if the phrases are too long the item cap drops step by step (32, 16, 8, counts
  /// only, then counts only without "with prefix"). Shape: "change NAME: Always · adds 1 host “evil.example”"; a rename
  /// shows both names ("change OLD (now NEW): …").
  ///
  /// Why the last form always fits (Characters; joining strings never adds a Character, it can only merge two):
  ///   "change " 7 + OLD 24 + " (now " 6 + NEW 24 + "): " 3                                   =  64
  ///   approval, longest "ask once per session"                                              =  20
  ///   folders, longest "adds 99+ folders" 16 + "removes 99+ folders" 19 ("any folder" 10,
  ///     "only in 99+ folders" 19 exclude both)                                              =  35
  ///   hosts "adds 99+ hosts" 14 + "removes 99+ hosts" 17                                    =  31
  ///   slot, longest "sent as header" 14; value "a new value" 11                             =  25
  ///   six " · " separators between seven phrases                                             =  18
  ///   total                                                                                  = 193 <= 200
  /// Counts are at most 3 Characters ("99+"; a record holds at most 20 hosts and 20 folders anyway). In scalars: each
  /// name is at most 72 (`cap`), everything else is one scalar per Character, so 7 + 72 + 6 + 72 + 3 + 129 = 289 <= 400.
  public static func changeReason(from old: SecretRecord, to new: SecretRecord) -> String? {
    let oldName = cap(clean(old.name), to: nameLimit), newName = cap(clean(new.name), to: nameLimit)
    let who = old.name == new.name ? newName : "\(oldName) (now \(newName))"
    var reason = ""
    for limit in itemLimits {
      let changes = ruleChanges(from: old, to: new, itemLimit: limit)
      guard !changes.isEmpty else { return nil }
      reason = "change \(who): " + changes.joined(separator: " · ")
      if fits(reason) { return reason }
    }
    // The last form, which fits by the arithmetic above.
    return reason
  }

  static let reasonLimit = 200
  static let nameLimit = 24
  /// The item cap, tried from the left; the last one (-1) always fits.
  static let itemLimits = [32, 16, 8, 0, -1]

  private static func fits(_ reason: String) -> Bool {
    // Characters for what the sheet shows, scalars so a pile of combining marks can't make it long anyway.
    reason.count <= reasonLimit && reason.unicodeScalars.count <= reasonLimit * 2
  }

  /// `text` without control, line-break, bidirectional, invisible format and blank-looking filler scalars (a name can't
  /// hide or reorder what the sheet says); control and line-break scalars become a space, the rest vanish.
  static func clean(_ text: String) -> String {
    var out = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
      switch scalar.value {
      case 0x202A...0x202E, 0x2066...0x2069, 0x200B...0x200F, 0xFEFF, 0x2060...0x2064, 0x061C, 0x180E,
           0x3164, 0x2800, 0x115F, 0x1160, 0xFFA0, 0x034F, 0xFE00...0xFE0F, 0xE0100...0xE01EF,
           0x17B4, 0x17B5, 0x180B...0x180D, 0x180F:
        continue
      case 0x2028, 0x2029, 0x85:
        space(&out)
      default:
        switch scalar.properties.generalCategory {
        // .spaceSeparator: no-break, en/em/thin/hair, ideographic and the other wide or narrow spaces.
        case .control, .lineSeparator, .paragraphSeparator, .spaceSeparator: space(&out)
        case .format, .unassigned, .privateUse, .surrogate: continue
        default: out.append(scalar)
        }
      }
    }
    return String(out).trimmingCharacters(in: .whitespaces)
  }

  /// One plain space, never two in a row.
  private static func space(_ out: inout String.UnicodeScalarView) {
    if out.last != " " { out.append(" ") }
  }

  /// Cuts to `limit` characters (grapheme clusters), ending with "…"; a cluster stuffed with combining marks is cut by
  /// scalars as well, so the result is short either way.
  static func cap(_ text: String, to limit: Int) -> String {
    var result = text
    if result.count > limit { result = String(result.prefix(limit - 1)) + "…" }
    let scalars = result.unicodeScalars
    if scalars.count > limit * 3 { result = String(String.UnicodeScalarView(scalars.prefix(limit * 3 - 1))) + "…" }
    return result
  }

  /// An item in “ ”, cleaned and capped. The quote marks and the separators the reason uses are replaced inside it, so
  /// a folder called "/tmp/x · Always" can't read as a phrase of its own.
  private static func quoted(_ item: String, _ limit: Int) -> String {
    // By scalar: a mark glued to a "·" makes a Character that is not "·".
    var safe = String.UnicodeScalarView()
    for scalar in clean(item).unicodeScalars {
      switch scalar {
      // Quote marks and their look-alikes.
      case "\u{201C}", "\u{201D}", "\"", "\u{201F}", "\u{FF02}", "\u{201E}", "\u{2018}", "\u{2019}", "\u{201A}":
        safe.append("'")
      // The reason's separators and their look-alikes: middle dots, bullets, Greek ano teleia, katakana middle dots.
      case "\u{00B7}", ",", "\u{2219}", "\u{2022}", "\u{30FB}", "\u{FF65}", "\u{0387}", "\u{22C5}", "\u{2027}":
        safe.append("_")
      default: safe.append(scalar)
      }
    }
    return "“" + cap(String(safe), to: limit) + "”"
  }

  /// "adds 3 folders “/Users/me/a…” +2": the count, ONE item, and how many more.
  private static func group(_ verb: String, _ noun: String, _ items: [String], _ limit: Int) -> String {
    func number(_ n: Int) -> String { n > 99 ? "99+" : String(n) }
    let base = "\(verb) \(number(items.count)) \(noun)\(items.count == 1 ? "" : "s")"
    guard limit > 0, let first = items.first else { return base }
    return base + " " + quoted(first, limit) + (items.count > 1 ? " +\(number(items.count - 1))" : "")
  }

  private static func describe(_ slot: SecretSlot, _ limit: Int) -> String {
    switch slot {
    case .bearer: return "sent as bearer"
    case .header(let name, let prefix):
      let base = limit > 0 ? "sent as header " + quoted(name, limit) : "sent as header"
      return prefix.isEmpty || limit < 0 ? base : base + " with prefix"
    case .basic(let username): return limit > 0 ? "sent as basic for " + quoted(username, limit) : "sent as basic"
    }
  }
}
